-include .env
export

provision:
	ansible-playbook -i "$(SERVER_HOST)," -u root ansible/provision.yaml

master-key:
	ansible-playbook -i "$(SERVER_HOST)," -u $(SERVER_USER) ansible/master-key.yaml

users:
	ansible-playbook -i "$(SERVER_HOST)," -u $(SERVER_USER) ansible/users.yaml

forget:
	ssh-keygen -R $(SERVER_HOST)

tunnel:
	ssh -L 6443:localhost:6443 $(SERVER_USER)@$(SERVER_HOST)

kubeconfig:
	scp $(SERVER_USER)@$(SERVER_HOST):/etc/rancher/rke2/rke2.yaml ./kubeconfig

bootstrap:
	@make kubeconfig
	GITHUB_TOKEN=$(GITHUB_PAT) flux bootstrap github \
		--kubeconfig=./kubeconfig \
		--owner=siegfriden \
		--repository=k8s-infra \
		--branch=main \
		--path=kubernetes \
		--personal
