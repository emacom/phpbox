import json
import os
import sys


def main():
    """Print COMPOSER_AUTH json from the first readable auth.json given as argument plus keys from the environment."""
    auth = {}
    for path in sys.argv[1:]:
        if os.access(path, os.R_OK):
            with open(path) as f:
                auth = json.load(f)
            break
    public, private = os.environ.get("MAGENTO_PUBLIC_KEY"), os.environ.get("MAGENTO_PRIVATE_KEY")
    if public and private:
        auth.setdefault("http-basic", {})["repo.magento.com"] = {"username": public, "password": private}
    if os.environ.get("GITHUB_TOKEN"):
        auth.setdefault("github-oauth", {})["github.com"] = os.environ["GITHUB_TOKEN"]
    print(json.dumps(auth) if auth else "")


main()
