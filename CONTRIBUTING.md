# Contributing

Thanks for taking a look. Sotto is a small personal project, so keep changes focused.

- Open an issue first for anything bigger than a bug fix, so we can agree on the approach before you write code.
- Work on a branch from `beta`. New features land there first; `main` is the stable channel.
- Build with `scripts/build.sh` (or `scripts/build.sh --beta`) and run the checks before opening a pull request:

  ```sh
  bash scripts/test-core.sh
  python3 scripts/check-recording-sounds.py
  python3 scripts/validate-dock-controller.py
  ```

- Say in the pull request what you tested by hand: a green build does not prove that the Fn shortcut, the microphone or pasting work.
- Keep Sotto local. Pull requests that send audio or text to a server by default will not be merged.
- By contributing you agree that your work is released under the GPL v3, like the rest of the project.

Security problems go through [SECURITY.md](SECURITY.md), not public issues.
