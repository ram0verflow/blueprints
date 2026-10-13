#!/bin/bash
# usage: etcd-cluster.sh [quota_bytes]   (re)creates a 3-member cluster on the host network
Q=${1:-33554432}
IC="etcd1=http://127.0.0.1:2380,etcd2=http://127.0.0.1:22380,etcd3=http://127.0.0.1:32380"
for n in 1 2 3; do docker rm -f etcd$n >/dev/null 2>&1; done
start() { # name clientport peerport
docker run -d --name $1 --network host quay.io/coreos/etcd:v3.5.17 etcd --name $1 --data-dir /data \
  --listen-client-urls http://127.0.0.1:$2 --advertise-client-urls http://127.0.0.1:$2 \
  --listen-peer-urls http://127.0.0.1:$3 --initial-advertise-peer-urls http://127.0.0.1:$3 \
  --initial-cluster $IC --initial-cluster-token test-cluster --initial-cluster-state new \
  --quota-backend-bytes $Q --auto-compaction-retention 0 >/dev/null
}
start etcd1 2379 2380; start etcd2 22379 22380; start etcd3 32379 32380
for i in $(seq 1 30); do docker exec etcd1 etcdctl --endpoints=http://127.0.0.1:2379,http://127.0.0.1:22379,http://127.0.0.1:32379 endpoint health >/dev/null 2>&1 && echo CLUSTER_UP && exit 0; sleep 1; done; echo CLUSTER_FAIL
