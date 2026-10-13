S=/tmp/claude-0/-home-user-blueprints/30ba1e55-d2b4-52ce-81ba-13d6e66cfcaf/scratchpad
# helpers: source me
A="admin@kestra.io:Admin1234!"; K="http://127.0.0.1:8080/api/v1/main"
kc() { curl -s --noproxy '*' -u "$A" "$@"; }
upload() { # file -> strips extend, creates or updates
  python3 -c "import sys;s=open(sys.argv[1]).read();i=s.find('\nextend:');open(sys.argv[2],'w').write(s if i<0 else s[:i+1])" "$1" /tmp/up.yaml
  id=$(grep -m1 '^id:' /tmp/up.yaml | awk '{print $2}')
  code=$(kc -o /tmp/up.out -w '%{http_code}' -X PUT "$K/flows/company.team/$id" -H 'Content-Type: application/x-yaml' --data-binary @/tmp/up.yaml)
  if [ "$code" = 404 ]; then code=$(kc -o /tmp/up.out -w '%{http_code}' -X POST "$K/flows" -H 'Content-Type: application/x-yaml' --data-binary @/tmp/up.yaml); fi
  echo "upload $id: $code"; [ "$code" = 200 ] || cat /tmp/up.out
}
wait_exec() { # id [maxsec]
  for i in $(seq 1 ${2:-300}); do st=$(kc "$K/executions/$1" | python3 -c "import json,sys;print(json.load(sys.stdin)['state']['current'])"); case $st in SUCCESS|FAILED|WARNING|KILLED|CANCELLED) break;; esac; sleep 1; done
  echo "STATE $st"
}
show() { # id: tasks + warn/error logs
  kc "$K/executions/$1" | python3 -c "
import json,sys;d=json.load(sys.stdin)
for t in d.get('taskRunList') or []: print('  ',t['taskId'],t['state']['current'],t['state'].get('duration',''))"
  kc "$K/logs/$1?minLevel=WARN" | python3 -c "
import json,sys
for l in json.load(sys.stdin): print('  LOG',l['level'],l['taskId'],l['message'][:400])"
}
F=etcd-snapshot-restore-drill
run() { kc -X POST "$K/executions/company.team/$F" "$@" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])"; }
infolog() { kc "$K/logs/$1" | python3 -c "
import json,sys
for l in json.load(sys.stdin):
  if l['level'] in ('INFO','WARN','ERROR') and l['taskId'] not in ('build_tools',) and 'Container' not in l['message'] and 'Volume' not in l['message']: print(l['level'][0],l['taskId'],l['message'][:600])"; }
outs() { kc "$K/outputs/executions/$1" | head -c ${2:-1500}; echo; }
sinknew() { python3 -c "
import json,sys
L=open('$S/sink.jsonl').read().splitlines()[int(sys.argv[1]):]
for l in L: print('SLACK>', json.loads(json.loads(l)['body']).get('text'))" ${1:-0}; }
sinkcount() { wc -l < $S/sink.jsonl; }
