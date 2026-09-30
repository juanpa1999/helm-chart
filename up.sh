#install de repo and the install de charts in order


helm repo add test-name https://juanpa1999.github.io/helm-chart
helm repo update
helm repo list
helm search repo test-repo

helm install db ak8s/db
#wait for it to be ready
helm install backend ak8s/backend
helm install front ak8s/frontend

#this will enable the test user and the test database to be created in the db deployment
kubectl exec -i deploy/db-deployment -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 < sql/seed_pablodevops.sql

#user: pablodevops pass: Test123456789*