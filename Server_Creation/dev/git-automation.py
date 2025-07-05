import os
import shutil
import subprocess
import re
import argparse

def run_cmd(cmd, cwd=None):
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[ERROR] Command failed: {cmd}")
        print(result.stderr)
        exit(1)
    return result.stdout.strip()

def clone_repo_if_needed(path, repo_url):
    repo_path = os.path.join(WORKSPACE_DIR, path)
    repo_dir = path.split('/')[0]
    if not os.path.exists(repo_path):
        print(f"🌀 Cloning {repo_dir}...")
        run_cmd(f"git clone {repo_url}", cwd=WORKSPACE_DIR)
    else:
        print(f"\n✅ Repo already cloned: {repo_dir}")
        print(f"🔄 Pulling latest changes for {repo_dir}...")
        run_cmd("git reset --hard", cwd=repo_path)
        run_cmd("git clean -fd", cwd=repo_path)
        run_cmd("git pull", cwd=repo_path)
    return os.path.join(WORKSPACE_DIR, path)

def replace_in_file(filepath, replacements):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except UnicodeDecodeError:
        print(f"⚠️ Skipping non-text or non-UTF8 file: {filepath}")
        return

    for old, new in replacements.items():
        content = content.replace(old, new)

    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)

def clone_and_modify_env(repo_path):
    # env_path = os.path.join(repo_path, 'environments')
    base_path = os.path.join(repo_path, BASE_CLIENT, BASE_ENV)
    new_path = os.path.join(repo_path, NEW_CLIENT, NEW_ENV)

    print(f"🔧 Processing: {repo_path}")
    print(f"📂 Base: {base_path}")
    print(f"📂 New : {new_path}")

    if not os.path.exists(base_path):
        print(f"❌ Base env not found: {base_path} — skipping repo")
        return

    if os.path.exists(new_path):
        print(f"⚠️ Env already exists: {new_path} — skipping")
        return

    os.makedirs(os.path.join(repo_path, NEW_CLIENT), exist_ok=True)
    shutil.copytree(base_path, new_path)

    for root, _, files in os.walk(new_path):
        for file in files:
            file_path = os.path.join(root, file)
            replace_in_file(file_path, {
                OLD_HOSTNAME: NEW_HOSTNAME,
                OLD_URL: NEW_URL
            })

    # run_cmd("git add .", cwd=repo_path)
    # commit_msg = f"Added new changes in {NEW_CLIENT}/{NEW_ENV} from {BASE_CLIENT}/{BASE_ENV} with updated hostname and URL"
    # run_cmd(f'git commit -m "{commit_msg}"', cwd=repo_path)
    # run_cmd("git push", cwd=repo_path)
    print(f"✅ Pushed new changes in : {repo_path}")
    
    # ✅ Only update Jenkinsfile if env copy succeeded
    update_jenkinsfile_if_needed(repo_path)

def update_jenkinsfile_if_needed(repo_path):
    if BASE_CLIENT == NEW_CLIENT:
        return  # No change needed

    repo_dir = os.path.dirname(repo_path) if repo_path.endswith("environments") else repo_path
    jenkinsfile_path = os.path.join(repo_dir, "Jenkinsfile")
    if not os.path.exists(jenkinsfile_path):
        print(f"⚠️ No Jenkinsfile found in {repo_dir}")
        return

    with open(jenkinsfile_path, 'r') as f:
        content = f.read()

    # Find the first occurrence of the env.CLIENT input line
    target_line_start = "env.CLIENT=input message"
    idx = content.find(target_line_start)

    if idx == -1:
        print("⚠️ Could not find 'env.CLIENT = input message' section in Jenkinsfile.")
        return

    # Find the start of the choices list
    choices_start = content.find("choices: [", idx)
    if choices_start == -1:
        print("⚠️ Could not find 'choices: [' in env.CLIENT block.")
        return

    list_start = choices_start + len("choices: [")
    list_end = content.find("]", list_start)
    if list_end == -1:
        print("⚠️ Could not find closing ']' for choices list.")
        return

    choices_str = content[list_start:list_end]
    choices_list = [c.strip().strip("'\"") for c in choices_str.split(",") if c.strip()]

    if NEW_CLIENT in choices_list:
        print(f"✔️ {NEW_CLIENT} already present in Jenkinsfile.")
        return

    choices_list.append(NEW_CLIENT)
    choices_list = sorted(set(choices_list))  # remove duplicates

    new_choices_str = ", ".join(f"'{c}'" for c in choices_list)

    # Replace the old list with the new one
    new_content = content[:list_start] + new_choices_str + content[list_end:]

    with open(jenkinsfile_path, 'w') as f:
        f.write(new_content)

    print(f"✏️ Jenkinsfile updated with new client: {NEW_CLIENT}")


# --- MAIN LOOP ---
if __name__ == "__main__":
    parser = argparse.ArgumentParser()

    parser.add_argument('--username', required=True)
    parser.add_argument('--token', required=True)
    parser.add_argument('--base-client', required=True)
    parser.add_argument('--base-env', required=True)
    parser.add_argument('--new-client', required=True)
    parser.add_argument('--new-env', required=True)
    parser.add_argument('--old-hostname', required=True)
    parser.add_argument('--new-hostname', required=True)
    parser.add_argument('--old-url', required=True)
    parser.add_argument('--new-url', required=True)
    parser.add_argument('--workspace_dir', required=True)

    args = parser.parse_args()

    # Assign parsed values to global config
    GITEA_USERNAME = args.username
    GITEA_TOKEN = args.token
    BASE_CLIENT = args.base_client
    BASE_ENV = args.base_env
    NEW_CLIENT = args.new_client
    NEW_ENV = args.new_env
    OLD_HOSTNAME = args.old_hostname
    NEW_HOSTNAME = args.new_hostname
    OLD_URL = args.old_url
    NEW_URL = args.new_url
    WORKSPACE_DIR = args.workspace_dir

# -------------------------
# CONFIGURATION START
# -------------------------

REPOS = {
    "jenkins-irf-encore-server/environments": f"https://{GITEA_USERNAME}:{GITEA_TOKEN}@vcs.perdix.co:3000/devops/jenkins-irf-encore-server.git",
    "jenkins-irf-perdix-bi/environments": f"https://{GITEA_USERNAME}:{GITEA_TOKEN}@vcs.perdix.co:3000/devops/jenkins-irf-perdix-bi.git",
    "jenkins-irf-perdix-client/environments": f"https://{GITEA_USERNAME}:{GITEA_TOKEN}@vcs.perdix.co:3000/devops/jenkins-irf-perdix-client.git",
    "jenkins-irf-perdix-server/environments": f"https://{GITEA_USERNAME}:{GITEA_TOKEN}@vcs.perdix.co:3000/devops/jenkins-irf-perdix-server.git",
    "environments": f"https://{GITEA_USERNAME}:{GITEA_TOKEN}@vcs.perdix.co:3000/devops/environments.git",
}

# -------------------------
# CONFIGURATION END
# -------------------------

if not os.path.exists(WORKSPACE_DIR):
    os.makedirs(WORKSPACE_DIR)

for path, url in REPOS.items():
    repo_path = clone_repo_if_needed(path, url)
    clone_and_modify_env(repo_path)
