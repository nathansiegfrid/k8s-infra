-include .env
export

.PHONY: tunnel kubeconfig bootstrap seal-secret forward-kyverno forward-linkerd

tunnel:
	ssh -L 6443:localhost:6443 $(SERVER_USER)@$(SERVER_HOST)

kubeconfig:
	scp $(SERVER_USER)@$(SERVER_HOST):/etc/rancher/k3s/k3s.yaml ./kubeconfig

bootstrap: kubeconfig
	GITHUB_TOKEN=$(GITHUB_PAT) flux bootstrap github \
		--kubeconfig=./kubeconfig \
		--owner=nathansiegfrid \
		--repository=k8s-infra \
		--branch=main \
		--path=kubernetes \
		--personal

seal-secret:
	kubeseal --format yaml < secret.yaml > sealed-secret.yaml

forward-kyverno:
	kubectl port-forward service/policy-reporter-ui 8082:8080 -n kyverno
forward-linkerd:
	kubectl port-forward service/web 8084:8084 -n linkerd-viz
