include .env

CLUSTER_NAME = saveh2o
CLUSTER_ID = $(shell curl -H "Authorization: Bearer ${CIVO_TOKEN}" https://api.civo.com/v2/kubernetes/clusters | jq '.items[] | select(.name == "saveh2o") | .id')

KUBECONFIG := --kubeconfig $$HOME/.kube/config
KUBECTL := kubectl $(KUBECONFIG)
HELM := helm $(KUBECONFIG)

# Kubernetes dashboard v2.0.0-rc5 released 3 set 2020
DASHBOARD = "https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.4/aio/deploy/recommended.yaml"

# Namespaces
MONITORING = monitoring			# Prometheus monitoring
STUDIO = studio					# Datastax Studio

ifeq ($(INGRESS),)
INGRESS = $(CLUSTER_ID).k8s.civo.com
endif

FAAS_BUILD_ARGS = --tag=branch
FAAS_FN = fn-mock.yml
# FAAS_FN = fn-prod.yml
FAAS_GATEWAY = http://$(INGRESS):31112

.DEFAULT_GOAL := help
.PHONY: all all-byoc all-mock ingress

all: 													## Deploy stack end to end
all: FAAS_FN=fn-prod.yml
all: provision deploy-core faas-create-secrets faas-up

all-byoc: 												## Deploy stack end to end (bring your own cluster)
all-byoc: FAAS_FN=fn-prod.yml
all-byoc: deploy-core faas-create-secrets faas-up

all-mock:												## Deploy stack end to end
all-mock: FAAS_FN=fn-mock.yml
all-mock: provision deploy-core faas-up

ingress:
	@echo "Ingress: $(INGRESS)"

##########################################################
##@ CLUSTER
##########################################################
.PHONY: provision kube-config dashboard-config

provision:												## Provision CIVO Cluster
	$(info Provisioning cluster..)
	@civo kubernetes create \
		--nodes 3 \
		--size "g2.medium" \
		--wait \
		$(CLUSTER_NAME) 

kube-config:											## Download and show KUBECONFIG
	@civo kubernetes config $(CLUSTER_NAME)

dashboard-config:
	@$(KUBECTL) -n kubernetes-dashboard describe secret admin-user-token | grep ^token

##########################################################
##@ DATABASE
##########################################################
.PHONY: deploy-db cassandra-operator config-map studio

deploy-db: cassandra-operator configmap studio			## Deploy Cassandra, ConfigMap and Studio

cassandra-operator:										## Deploy Cassandra Operator
	@$(info Deploying Cassandra Operator)
	@$(KUBECTL) create namespace cass-operator --dry-run=client -o yaml | $(KUBECTL) apply -f -
	@$(KUBECTL) -n cass-operator apply -f deploy/cassandra/02-storageclass-kind.yaml
	@$(KUBECTL) -n cass-operator apply -f deploy/cassandra/03-install-cass-operator-v1.3.yaml
	@sleep 5
	@$(KUBECTL) -n cass-operator apply -f deploy/cassandra/04-cassandra-cluster-1nodes.yaml

configmap:												## Deploy ConfigMap
	@cat deploy/cassandra/05-configMap.yaml | \
		sed "s/superuserpassword/$(shell $(KUBECTL) get secret cluster1-superuser -n cass-operator -o yaml | grep -m1 -Po 'password: \K.*' | base64 -d && echo "")/" - \
		> deploy/cassandra/configMap.yaml

studio:													## Deploy Studio
	@$(KUBECTL) create namespace $(STUDIO) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	@$(KUBECTL) -n $(STUDIO) apply -f deploy/cassandra/configMap.yaml
	@$(KUBECTL) -n $(STUDIO) apply -f deploy/cassandra/studio.yaml

##########################################################
##@ CORE APPS
##########################################################
.PHONY: core dashboard prometheus pushgateway

core: 													## Deploy core applications
core: dashboard prometheus pushgateway

dashboard:
	@$(info Deploying Dashboard)
	@$(KUBECTL) create -f $(DASHBOARD)
	@$(KUBECTL) create -f deploy/dashboard/dashboard.admin-user.yaml -f deploy/dashboard/dashboard.admin-user-role.yaml

prometheus:												## Deploy Prometheus Operator
	@$(info Deploying Prometheus Operator)
	@$(KUBECTL) create namespace $(MONITORING) --dry-run=client -o yaml | $(KUBECTL) apply -f -
	@$(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts
	@$(HELM) repo add stable https://kubernetes-charts.storage.googleapis.com/
	@$(HELM) repo update
	@$(HELM) install prometheus prometheus-community/kube-prometheus-stack \
		--namespace $(MONITORING) \
		--values deploy/prom/prometheus-operator-values.yaml \
		--wait

pushgateway:											## Deploy Prometheus Push Gateway
	$(info Deploying Prometheus Push Gateway)
	$(HELM) repo update
	$(HELM) upgrade --install \
		--create-namespace $(MONITORING) \
		--values deploy/pushgateway/values.yaml \
		--version 1.3.0 \
		--wait \
		metrics-sink stable/prometheus-pushgateway
	
##########################################################
##@ UTIL
##########################################################
.PHONY: proxies kill-proxies kill-prometheus help clean

proxies:												## Proxy all services
	@echo http://localhost:8001 dashboard
	@echo http://localhost:9090 prometheus
	@echo http://localhost:9093 alertmanager
	@echo http://localhost:8080 grafana
	@echo http://localhost:9091 studio

	@$(KUBECTL) proxy &
	@$(KUBECTL) port-forward -n $(MONITORING) $(shell $(KUBECTL) get pods -n $(MONITORING) -l "app=prometheus" -o name)  9090:9090 &
	@$(KUBECTL) port-forward -n $(MONITORING) $(shell $(KUBECTL) get pods -n $(MONITORING) -l "app=alertmanager" -o name)  9093:9093 &
	@$(KUBECTL) port-forward -n $(MONITORING) svc/prometheus-grafana 8080:80 &
	@$(KUBECTL) port-forward -n $(STUDIO) $(shell $(KUBECTL) get pods -n $(STUDIO) -l "app=studio-lb" -o name)  9091:9091 &

kill-proxies:											## Kill proxies (kills all kubectl processes)
	@pkill kubectl || true

kill-prometheus:										## Kill prometheus monitoring
	@$(HELM) uninstall -n $(MONITORING) prometheus
	@$(KUBECTL) delete --ignore-not-found crd prometheuses.monitoring.coreos.com
	@$(KUBECTL) delete --ignore-not-found crd prometheusrules.monitoring.coreos.com
	@$(KUBECTL) delete --ignore-not-found crd servicemonitors.monitoring.coreos.com
	@$(KUBECTL) delete --ignore-not-found crd podmonitors.monitoring.coreos.com
	@$(KUBECTL) delete --ignore-not-found crd alertmanagers.monitoring.coreos.com
	@$(KUBECTL) delete --ignore-not-found crd thanosrulers.monitoring.coreos.com
	@$(KUBECTL) delete --ignore-not-found crd probes.monitoring.coreos.com
	@$(KUBECTL) delete ns $(MONITORING)

kill-dashboard:
	@$(KUBECTL) delete -f $(DASHBOARD)
	@$(KUBECTL) delete -f deploy/dashboard/dashboard.admin-user.yaml -f deploy/dashboard/dashboard.admin-user-role.yaml

help:													## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m 	%s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

clean: kill-proxies										## Destroy cluster
	civo k8s delete $(CLUSTER_NAME)

##########################################################
##@ Faas Core
##########################################################
.PHONY: openfaas cron-connector mock-server

openfaas: cron-connector mock-server

openfaas:												## Deploy OpenFaaS
	@$(KUBECTL) apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml

	@$(HELM) repo add openfaas https://openfaas.github.io/faas-netes/

	@$(KUBECTL) -n openfaas create secret generic basic-auth \
	--from-literal=basic-auth-user=admin \
	--from-literal=basic-auth-password="$(ADMIN_PASSWORD)" \
	--dry-run -o yaml | $(KUBECTL) apply -f -

	@$(HELM) repo update
	@$(HELM) upgrade --install \
		--namespace openfaas  \
		--set basic_auth=true \
		--set functionNamespace=openfaas-fn \
		--version 5.4.0 \
		--wait \
		openfaas openfaas/openfaas

cron-connector:											## Deploy Cron Connector
	$(info Deploying Cron Connector)
	$(KUBECTL) apply -f deploy/cron-connector

mock-server:											## Deploy Mock Server
	$(info Deploying Mock Server)
	$(KUBECTL) kustomize \
		https://github.com/gabeduke/wio-mock/deploy?ref=master | $(KUBECTL) apply -n default -f -

##########################################################
##@ Faas Util
##########################################################
.PHONY: faas-build faas-push faas-deploy faas-up faas-down faas-create-secrets faas-login

faas-build: export DOCKER_BUILDKIT=1
faas-build: faas-login										## Build Docker images using Buildkit
	faas build --gateway $(FAAS_GATEWAY) $(FAAS_BUILD_ARGS) -f $(FAAS_FN)

faas-push: faas-login										## Push Docker images to registry
	faas push --gateway $(FAAS_GATEWAY) $(FAAS_BUILD_ARGS) -f $(FAAS_FN)

faas-deploy: faas-login										## Deploy functions to cluster
	faas deploy --gateway $(FAAS_GATEWAY) $(FAAS_BUILD_ARGS) -f $(FAAS_FN)

faas-up: export DOCKER_BUILDKIT=1
faas-up: faas-login											## Build, push and deploy all functions
	faas up --gateway $(FAAS_GATEWAY) $(FAAS_BUILD_ARGS) -f $(FAAS_FN)

faas-down: faas-login										## Remove all functions
	faas remove --gateway $(FAAS_GATEWAY) -f $(FAAS_FN)

faas-create-secrets: faas-login								## Create FaaS secrets
	faas --gateway $(FAAS_GATEWAY) secret create --from-literal=$(WIO1) wio1
	faas --gateway $(FAAS_GATEWAY) secret create --from-literal=$(WIO2) wio2
	faas --gateway $(FAAS_GATEWAY) secret create --from-literal=$(WIO3) wio3

faas-login:													## Log in to OpenFaaS
	faas login --gateway $(FAAS_GATEWAY) -u admin -p $(ADMIN_PASSWORD)
