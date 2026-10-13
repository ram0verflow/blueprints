docker rm -f kestra >/dev/null 2>&1
docker run -d --name kestra --network host --user root \
  -e SECRET_SLACK_WEBHOOK_URL=$(printf http://127.0.0.1:9999/slack | base64 -w0) \
  -v /tmp/claude-0/-home-user-blueprints/30ba1e55-d2b4-52ce-81ba-13d6e66cfcaf/scratchpad/kestra.yml:/etc/config/application.yml \
  -v /var/run/docker.sock:/var/run/docker.sock -v /tmp/kestra-wd:/tmp/kestra-wd \
  kestra/kestra:latest server local --config /etc/config/application.yml >/dev/null
for i in $(seq 1 80); do curl -s -o /dev/null -w "%{http_code}" --noproxy '*' -u "admin@kestra.io:Admin1234!" http://127.0.0.1:8080/api/v1/configs | grep -q 200 && echo READY && break; sleep 3; done
