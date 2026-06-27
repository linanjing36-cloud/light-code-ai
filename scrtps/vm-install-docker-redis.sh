#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> apt update"
apt-get update -y

echo "==> install Docker from Ubuntu repo (Tsinghua mirror)"
apt-get install -y docker.io docker-compose-v2

systemctl enable docker
systemctl start docker

echo "==> docker registry mirrors (CN)"
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://docker.1panel.live"
  ]
}
EOF
systemctl restart docker
sleep 3

echo "==> pull & run Redis Stack (via mirror prefix)"
docker rm -f redis-stack 2>/dev/null || true
docker pull docker.m.daocloud.io/redis/redis-stack-server:latest
docker tag docker.m.daocloud.io/redis/redis-stack-server:latest redis/redis-stack-server:latest
docker run -d \
  --name redis-stack \
  --restart unless-stopped \
  -p 0.0.0.0:6379:6379 \
  -p 0.0.0.0:8001:8001 \
  -v redis-stack-data:/data \
  redis/redis-stack-server:latest

echo "==> verify"
docker ps --filter name=redis-stack
docker exec redis-stack redis-cli PING
docker exec redis-stack redis-cli MODULE LIST | head -15
echo "==> DONE Redis Stack 192.168.59.129:6379"
