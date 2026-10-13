#!/bin/bash
# Full test matrix against a fresh 3-member etcd cluster and a fresh Kestra (state in KV starts empty).
# usage: matrix.sh [first_case] ; results appended to $S/results.txt
S=/tmp/claude-0/-home-user-blueprints/30ba1e55-d2b4-52ce-81ba-13d6e66cfcaf/scratchpad
. $S/k.sh
EPS=http://127.0.0.1:2379,http://127.0.0.1:22379,http://127.0.0.1:32379
R=$S/results.txt
ctl() { docker run --rm --network host kestra-etcd-tools:v3.5.17 etcdctl --endpoints=$EPS "$@"; }
state() { kc "$K/executions/$1" | python3 -c "import json,sys;print(json.load(sys.stdin)['state']['current'])"; }
wait_paused() { for i in $(seq 1 180); do st=$(state $1); case $st in PAUSED|SUCCESS|FAILED|WARNING) break;; esac; sleep 1; done; echo $st; }
wait_done() { for i in $(seq 1 ${2:-400}); do st=$(state $1); case $st in SUCCESS|FAILED|WARNING|KILLED) break;; esac; sleep 1; done; echo $st; }
msgs() { python3 -c "
import json,sys
for l in open('$S/sink.jsonl').read().splitlines()[int(sys.argv[1]):]: print(json.loads(json.loads(l)['body']).get('text'))" $1; }
# case <name> <exec> <expected state> <python condition on M (all new messages joined) and O (flow outputs)>
case_check() {
  local name=$1 e=$2 want=$3 cond=$4 n0=$5
  local st=$(wait_done $e)
  msgs $n0 > /tmp/m.txt; kc "$K/outputs/executions/$e" > /tmp/o.json
  local ok=$(python3 -c "
import json,sys
M=open('/tmp/m.txt').read(); N=M.count('etcd main')
try: O=json.load(open('/tmp/o.json'))
except Exception: O={}
D=O.get('drill',{}) if isinstance(O,dict) else {}
print('PASS' if ('$st'=='$want' and ($cond)) else 'FAIL')")
  echo "[$ok] $name: state=$st (want $want) exec=$e" | tee -a $R
  sed 's/^/      | /' /tmp/m.txt | tee -a $R
}
seed() { python3 $S/seed.py "$@" >/dev/null; }
hot() { # overwrite N hot keys R rounds with 500 KB values: history that only compaction frees
  for r in $(seq 1 $2); do python3 $S/seed.py /registry/leases/hot- $1 500000 >/dev/null 2>&1 || return 1; done; }

echo "=== matrix $(date -u +%FT%TZ) on $(kc http://127.0.0.1:8080/api/v1/configs | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])')" | tee -a $R

# T1 first run, healthy cluster with 500 keys
seed /registry/pods/default/web- 300 200; seed /registry/configmaps/app- 200 1000; seed /registry/pods/default/web- 100 300
n=$(sinkcount); e=$(run); case_check "T1 first run, healthy cluster" $e SUCCESS "N==1 and 'Restore drill PASS: new snapshot' in M and D.get('verdict')=='PASS' and D['sample']['checked']==50" $n

# T2 nothing changed
n=$(sinkcount); e=$(run); case_check "T2 nothing changed" $e SUCCESS "N==0 and D.get('verdict')=='PASS'" $n

# T3 writes during the drill: compared at the snapshot revision, so no false mismatch
(for i in 1 2 3 4 5 6 7 8; do seed /registry/pods/default/web- 300 250; done) & W=$!
sleep 1; n=$(sinkcount); e=$(run); wait $W
case_check "T3 400 keys rewritten during the drill" $e SUCCESS "N==0 and D['live']['current_revision']>D['snapshot']['revision'] and D['sample']['mismatch_count']==0" $n

# T4-T6 uploaded backups
mkdir -p $S/snaps; rm -f $S/snaps/*.db
docker run --rm --network host -v $S/snaps:/out kestra-etcd-tools:v3.5.17 etcdctl --endpoints=http://127.0.0.1:2379 snapshot save /out/good.db >/dev/null 2>&1
python3 - $S/snaps <<'EOF'
import sys
d=sys.argv[1]; g=open(d+'/good.db','rb').read(); b=bytearray(g)
for i in range(len(b)//2, len(b)//2+64): b[i]^=0xFF
open(d+'/corrupt.db','wb').write(b); open(d+'/truncated.db','wb').write(g[:len(g)//3])
EOF
seed /registry/pods/default/web- 50 100   # the live cluster moves on after the backup
n=$(sinkcount); e=$(run -F "snapshot=@$S/snaps/corrupt.db"); case_check "T4 uploaded backup with 64 flipped bytes" $e WARNING "N==1 and 'Restore drill FAIL (uploaded file' in M and 'SHA-256 does not match' in M" $n
n=$(sinkcount); e=$(run -F "snapshot=@$S/snaps/truncated.db"); case_check "T5 uploaded backup cut to a third" $e WARNING "N==1 and 'no SHA-256 trailer' in M" $n
n=$(sinkcount); e=$(run -F "snapshot=@$S/snaps/good.db"); case_check "T6 good uploaded backup, older than the live data" $e SUCCESS "N==1 and 'RECOVERED Restore drill PASS: uploaded file' in M and D['live']['current_revision']>D['snapshot']['revision']" $n

# T7 the leader goes down; Alertmanager calls the webhook
L=$(ctl endpoint status -w json | python3 -c "import json,sys;print([s['Endpoint'] for s in json.load(sys.stdin) if s['Status']['leader']==s['Status']['header']['member_id']][0])")
LN=$(case $L in *:2379) echo etcd1;; *:22379) echo etcd2;; *) echo etcd3;; esac); echo "leader: $LN" | tee -a $R
docker stop $LN >/dev/null; sleep 3
n=$(sinkcount)
e=$(curl -s --noproxy '*' -X POST "$K/executions/webhook/company.team/$F/etcd-drill-change-me" -H 'Content-Type: application/json' \
  -d '{"status":"firing","commonLabels":{"alertname":"etcdMembersDown","job":"etcd"},"alerts":[]}' | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
case_check "T7 leader $LN stopped, run started by the Alertmanager webhook" $e WARNING "N==1 and 'Alertmanager: etcdMembersDown' in M and 'DOWN $LN' in M and 'cannot lose another one' in M and D.get('verdict')=='PASS'" $n
n=$(sinkcount); e=$(run); case_check "T8 still down: no repeat" $e WARNING "N==0" $n
docker start $LN >/dev/null; sleep 5
n=$(sinkcount); e=$(run); case_check "T9 member back" $e SUCCESS "N==1 and 'UP $LN answers again' in M" $n

# T10 history builds up (5 hot keys rewritten), database passes 70% of the 32 MiB quota
hot 5 9
ctl endpoint status -w table | tee -a $R
n=$(sinkcount); e=$(run); case_check "T10 database above the warning level" $e SUCCESS "N==1 and M.count('WARN etcd')==3 and 'maintenance available' not in M" $n

# T11 NOSPACE: on-call declines
hot 5 6; ctl alarm list | tee -a $R
n=$(sinkcount); e=$(run); st=$(wait_paused $e); echo "T11 paused: $st" | tee -a $R
B=$(ctl endpoint status -w json | python3 -c "import json,sys;print(sorted(s['Status']['dbSize'] for s in json.load(sys.stdin)))")
kc -X POST "$K/executions/$e/actions/resume" >/dev/null
A=$(sleep 15; ctl endpoint status -w json | python3 -c "import json,sys;print(sorted(s['Status']['dbSize'] for s in json.load(sys.stdin)))")
echo "      sizes before/after decline: $B / $A" | tee -a $R
case_check "T11 NOSPACE alarm, proposal, on-call declines" $e WARNING "'ALARM NOSPACE on' in M and M.count('CRITICAL etcd')==3 and 'maintenance available' in M and 'no maintenance chosen; nothing was changed' in M and 'carries the NOSPACE alarm' in json.dumps(D) and '$B'=='$A'" $n

# T12 same state within ask_again_hours: no new message, no pause
n=$(sinkcount); e=$(run); case_check "T12 still NOSPACE, asked an hour ago: quiet" $e WARNING "N==0" $n

# T13 late approval: a follower stops while the proposal waits
n=$(sinkcount); e=$(run -F ask_again_hours=0); st=$(wait_paused $e); echo "T13 paused: $st" | tee -a $R
F1=$(ctl endpoint status -w json | python3 -c "import json,sys;d=json.load(sys.stdin);print([{'2379':'etcd1','22379':'etcd2','32379':'etcd3'}[s['Endpoint'].rsplit(':',1)[1]] for s in d if s['Status']['leader']!=s['Status']['header']['member_id']][0])")
docker stop $F1 >/dev/null; sleep 2
kc -X POST "$K/executions/$e/actions/resume" -F 'actions=["Compact history","Defragment members one at a time","Disarm the NOSPACE alarm"]' >/dev/null
case_check "T13 approved after follower $F1 stopped" $e WARNING "'Defragmentation NOT started: $F1 not responding' in M and 'NOSPACE NOT disarmed' in M and 'compacted history up to revision' in M" $n
docker start $F1 >/dev/null; sleep 5

# T14 approve everything on a healthy cluster
n=$(sinkcount); e=$(run -F ask_again_hours=0); st=$(wait_paused $e); echo "T14 paused: $st" | tee -a $R
LN=$(ctl endpoint status -w json | python3 -c "import json,sys;d=json.load(sys.stdin);print([{'2379':'etcd1','22379':'etcd2','32379':'etcd3'}[s['Endpoint'].rsplit(':',1)[1]] for s in d if s['Status']['leader']==s['Status']['header']['member_id']][0])")
kc -X POST "$K/executions/$e/actions/resume" -F 'actions=["Compact history","Defragment members one at a time","Disarm the NOSPACE alarm"]' >/dev/null
st=$(wait_done $e); ctl endpoint status -w table | tee -a $R; ctl alarm list | tee -a $R
W=$(python3 $S/seed.py /registry/pods/default/after-maintenance- 1 10 2>&1 | tail -1); echo "      write after maintenance: $W" | tee -a $R
case_check "T14 approve all three, leader $LN" $e SUCCESS "'NOSPACE disarmed' in M and (lambda P: P.index('$LN (leader)') > P.rindex('(follower)') and P.count('(follower)')==2)(M[M.rindex('maintenance: Compact'):]) and 'CLEARED alarm NOSPACE' in M and 'seeded 1' in '''$W'''" $n
n=$(sinkcount); e=$(run); case_check "T15 next run after maintenance: quiet" $e SUCCESS "N==0" $n

# T16 quorum lost
docker stop etcd2 etcd3 >/dev/null; sleep 3
n=$(sinkcount); e=$(run); case_check "T16 two of three members stopped" $e WARNING "'QUORUM LOST: only 1 of 3' in M and 'DOWN etcd2' in M and 'DOWN etcd3' in M" $n
docker start etcd2 etcd3 >/dev/null; sleep 6

# T17 cluster unreachable
n=$(sinkcount); e=$(run -F endpoints=http://127.0.0.1:2999); case_check "T17 wrong endpoint" $e FAILED "N==1 and 'drill failed' in M and 'at \`probe\`: Cannot reach the etcd cluster' in M" $n
echo "=== done" | tee -a $R
