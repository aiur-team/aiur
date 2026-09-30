from pathlib import Path
import tempfile,subprocess,shutil,os,json,sys
s=Path(sys.argv[1])
y=(s/".github/workflows/release-npm.yml").read_text()
block=y.split("      - name: Verify checked-in package versions match mix.exs\n",1)[1].split("\n      #",1)[0]
lines=block.splitlines(); assert lines[0].strip()=="run: |"
command="\n".join(line[10:] for line in lines[1:] if line.strip())
with tempfile.TemporaryDirectory(prefix="release-version-probe-") as temp:
 root=Path(temp)
 for file in ["src/mix.exs","packaging/npm/aiur-cli/package.json","packaging/scripts/resolve-version.mjs"]:
  p=root/file;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(s/file,p)
 env={k:v for k,v in os.environ.items() if not k.startswith("GITHUB_")}
 for name in ["baseline","mix_only_bump","synchronized"]:
  if name=="mix_only_bump":
   p=root/"src/mix.exs";p.write_text(p.read_text().replace('version: "0.0.5"','version: "0.0.6"',1))
  elif name=="synchronized":
   p=root/"packaging/npm/aiur-cli/package.json";d=json.loads(p.read_text());d["version"]="0.0.6";p.write_text(json.dumps(d))
  result=subprocess.run(["bash","-c",command],cwd=root,env=env,capture_output=True,text=True)
  assert result.returncode==(1 if name=="mix_only_bump" else 0),(name,result)
  print(name,result.returncode,result.stdout.strip())
