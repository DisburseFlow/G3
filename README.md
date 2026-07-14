
Step by step guide to get started with the `G3` repository
---

### Step 1: The Dev Clones the Repo

A new developer clones the repo recursively so they actually get the code files inside `frontend` and `backend`:

```bash
git clone --recursive https://github.com/DisburseFlow/G3.git
cd G3

```

---

### Step 2: Making and Pushing Changes to a Submodule

By default, Git leaves submodules in a **"detached HEAD"** state (it just points to a specific commit hash). Before making changes, the developer *must* switch to a working branch (like `develop` or `main`) inside that specific directory.

Let's say they want to change something in the **frontend**:

1. **Navigate into the frontend directory:** Moves into the submodule repository.
```bash
cd frontend

```


2. **Checkout your working branch:** Crucial! This tells Git which branch to apply changes to.
```bash
git checkout develop   # or main, whichever branch your fork uses

```


3. **Make the code changes:** Do your coding work here.
Modify the files, test them, and make sure everything works.


4. **Commit and Push the frontend changes:** This pushes ONLY to the frontend fork repository.
```bash
git add .
git commit -m "fix: updated dashboard layout"
git push origin develop

```


---

### Step 3: Updating the Parent `G3` Repo (The Missing Link)

Right now, the changes are live on the `stellar-disbursement-platform-frontend` fork, but your parent `G3` repo is still pointing to the old commit hash (`e32a4e5`).

The developer needs to go back to the root `G3` directory and tell `G3` to track the new commit:

1. **Navigate back to G3 root:** Go back up to the main project folder.
```bash
cd ..

```


2. **Check git status:** Notice that Git sees 'frontend' has a new commit pointer.
Run `git status`. You will see something like:

```text
Changes not staged for commit:
  modified:   frontend (new commits)

```


3. **Commit and Push the pointer update:** This saves the new folder pointer hash into G3.
```bash
git add frontend
git commit -m "chore: update frontend submodule pointer"
git push origin main

```


---

### Summary of what just happened:

1. The code changes were pushed directly to your **Frontend Fork**.
2. A new commit pointer hash was pushed to **G3**.

Now, when any other developer runs `git pull --recurse-submodules` on `G3`, their local machine will see the updated pointer and automatically download the new frontend code!