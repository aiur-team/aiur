# MP-R1 census output

Commands target main `889212aa39a2fb992da7942c6e4236f7b70be376`.
Local checkout prefixes are rendered as `<isolated-main>` or `<workspace>`;
ANSI color codes and blank output lines are removed. Result lines are otherwise unchanged.

## 18-historical-census

Working directory: report checkout; read-only historical objects.

Command:

```sh
python3 <allowance-census.py printed below>
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:41:33.058922Z
UTC end: 2026-10-26T11:41:33.131442Z
Exit code: 0
Original member merge commits checked: 67
7938d2d5ff2df88d0f4b226aa2510ab9aab1d171 allowance rows: 0 -> 441
757434b4fce4b93b4fe72cd6226fb92c23791cb9 allowance rows: 405 -> 747
e91b997f6d32d4cb8eaf3c0afc641079c353c3c7 allowance rows: 586 -> 589
74dc7a1b592c732a5057413f1cb3469eaeec5776 allowance rows: 573 -> 577
c96025161f1688888de4159d8c31fb117a989b6a allowance rows: 521 -> 545
```

Reproduction script (reads the original member table and immutable Git objects):

```python
import json,os,re,subprocess
from pathlib import Path
workspace=os.environ['AIUR_AGENT_WORKSPACE']
main='889212aa39a2fb992da7942c6e4236f7b70be376'
text=(Path(workspace)/'docs/research/aiur-mobile-and-platform/acceptance/MP-R1/members.md').read_text().split('## GHA extension')[0]
shas=re.findall(r'\| `([0-9a-f]{40})` \|',text)
assert len(shas)==67
batch=subprocess.Popen(['git','-C',workspace,'cat-file','--batch'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
cache={}
def read(key):
 if key in cache:return cache[key]
 batch.stdin.write((key+'\n').encode());batch.stdin.flush()
 header=batch.stdout.readline().decode().split()
 if header[-1]=='missing':return None
 size=int(header[-1]);data=batch.stdout.read(size);assert batch.stdout.read(1)==b'\n';cache[key]=data
 return data
def count(ref):
 tree=read(ref+':scripts/components/allowlist')
 if tree is None:return 0
 total=0
 while tree:
  end=tree.index(b'\0');oid=tree[end+1:end+21].hex();tree=tree[end+21:]
  total+=sum(bool(line.strip()) and not line.startswith('#') for line in read(oid).decode().splitlines())
 return total
print('Original member merge commits checked:',len(shas))
for sha in shas:
 before,after=count(sha+'^'),count(sha)
 if after>before:print(sha, 'allowance rows:',before,'->',after)
batch.stdin.close();assert batch.wait()==0
```

## 19-dispositions

Working directory: `report checkout; read-only tracker snapshot`.

Command:

```sh
gh api graphql -f 'query=query{repository(owner:"aiur-team",name:"aiur"){issue(number:3828){number title state} flag:issue(number:3288){number state stateReason} refresh:issue(number:3339){number state stateReason}}}'
```

```text
SHA: 889212aa39a2fb992da7942c6e4236f7b70be376
UTC start: 2026-10-26T11:42:40.209606Z
UTC end: 2026-10-26T11:42:41.137543Z
Exit code: 0
{"data":{"repository":{"issue":{"number":3828,"title":"MP-R1-GHA-6: Record the github-access promotion test and promote it on go","state":"OPEN"},"flag":{"number":3288,"state":"CLOSED","stateReason":"NOT_PLANNED"},"refresh":{"number":3339,"state":"CLOSED","stateReason":"COMPLETED"}}}}
```
