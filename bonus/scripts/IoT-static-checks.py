#!/usr/bin/env python3
"""Static sanity checks. Does NOT substitute for VM/Kubernetes runtime tests."""
from pathlib import Path
import re
import shutil
import subprocess
import sys

try:
    import yaml
except ImportError:
    print('PyYAML missing: python3 -m pip install PyYAML', file=sys.stderr)
    sys.exit(2)

R = Path(__file__).resolve().parents[2]
all_yaml = sorted(R.glob('*/confs/**/*.yaml'))
count = 0
for path in all_yaml:
    docs = list(yaml.safe_load_all(path.read_text()))
    for d in docs:
        if d is None:
            continue
        if not isinstance(d, dict):
            raise AssertionError(f'{path}: YAML document is not a mapping')
        required_fields = ('apiVersion', 'kind') if d.get('kind') == 'Kustomization' else ('apiVersion', 'kind', 'metadata')
        for required in required_fields:
            if required not in d:
                raise AssertionError(f'{path}: missing {required}')
        count += 1

p2 = [x for x in yaml.safe_load_all((R/'p2/confs/IoT-apps.yaml').read_text()) if x]
by_kind = {}
for item in p2:
    by_kind.setdefault(item['kind'], []).append(item)
assert len(by_kind['Deployment']) == len(by_kind['ConfigMap']) == len(by_kind['Service']) == 3
assert len(by_kind['Ingress']) == 1
replicas = {x['metadata']['name']: x['spec']['replicas'] for x in by_kind['Deployment']}
assert replicas == {'iot-app1': 1, 'iot-app2': 3, 'iot-app3': 1}, replicas
spec = by_kind['Ingress'][0]['spec']
rules = spec['rules']

# Validate hostname-specific routing.
hosts = {
    rule['host']: rule['http']['paths'][0]['backend']['service']['name']
    for rule in rules if 'host' in rule
}
assert hosts == {'app1.com': 'iot-app1', 'app2.com': 'iot-app2'}

# Validate catch-all fallback routing to App3.
fallback = [rule for rule in rules if 'host' not in rule]
assert len(fallback) == 1
assert fallback[0]['http']['paths'][0]['backend']['service']['name'] == 'iot-app3'
assert fallback[0]['http']['paths'][0]['path'] == '/'
assert fallback[0]['http']['paths'][0]['pathType'] == 'Prefix'

p3 = yaml.safe_load((R/'p3/confs/apps/IoT-deployment.yaml').read_text())
assert p3['metadata']['namespace'] == 'dev'
assert p3['spec']['template']['spec']['containers'][0]['image'] in ('wil42/playground:v1', 'wil42/playground:v2')
app = yaml.safe_load((R/'p3/confs/IoT-github-application.template.yaml').read_text())
assert app['spec']['source']['path'] == 'p3/confs/apps'
assert app['spec']['syncPolicy']['automated'] == {'prune': True, 'selfHeal': True}
gitlab_app = yaml.safe_load((R/'bonus/confs/IoT-argocd-gitlab-application.yaml').read_text())
assert gitlab_app['spec']['source']['repoURL'].startswith('http://gitlab.gitlab.svc.cluster.local:8081/')
assert gitlab_app['spec']['destination']['namespace'] == 'dev'
gitlab = list(yaml.safe_load_all((R/'bonus/confs/IoT-gitlab.yaml').read_text()))
assert {x['kind'] for x in gitlab} == {'Deployment', 'PersistentVolumeClaim', 'Service'}
assert all(x['metadata']['namespace'] == 'gitlab' for x in gitlab)
assert next(x for x in gitlab if x['kind'] == 'Deployment')['spec']['template']['spec']['containers'][0]['image'] == 'gitlab/gitlab-ce:19.5.9-ce.0'

assert set(x.name for x in R.iterdir() if x.is_dir() and not x.name.startswith(".")) == {'p1','p2','p3','bonus'}
for part in ('p1','p2','p3','bonus'):
    assert (R/part/'scripts').is_dir()
    assert (R/part/'confs').is_dir()
assert not (R/'p3/Vagrantfile').exists()
assert '192.168.56.110' in (R/'p1/Vagrantfile').read_text()
assert '192.168.56.111' in (R/'p1/Vagrantfile').read_text()

for file in sorted(R.glob('*/scripts/*.sh')):
    subprocess.run(['bash','-n',str(file)],check=True)
for file in (R/'p1/Vagrantfile',R/'p2/Vagrantfile'):
    subprocess.run(['ruby','-c',str(file)],check=True,stdout=subprocess.DEVNULL)
print(f'PASS: {count} Kubernetes YAML resources, Vagrant Ruby, bash syntax and subject requirements')
print('NOT RUN: Vagrant guest boot, K3s/K3d, GitLab bootstrap, live ingress and GitOps updates')
