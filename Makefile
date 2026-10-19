.PHONY: venv lint format test sync-books check-upstream-books docs docs-serve

# One dev venv for lint, test and docs, built by uv from pyproject.toml + uv.lock
# (Python version from .python-version). Rebuilt whenever any of them changes.
.venv: pyproject.toml uv.lock .python-version
	uv sync
	@touch .venv

venv: .venv

lint: .venv
	.venv/bin/ruff check .
	.venv/bin/basedpyright skills/productivity/timesheet/scripts/digest_sessions.py \
		skills/productivity/writing-great-skills/scripts/check-description-length.py

format: .venv
	.venv/bin/ruff format .

# Tests for the deterministic-gate scripts bundled under skills/**/scripts/.
# Python scripts via pytest; shell scripts via their own assertion runners.
test: .venv
	.venv/bin/pytest skills -q
	bash skills/engineering/setup-zsl-superpowers/scripts/tests/test_set_status_options.sh
	bash skills/engineering/setup-zsl-superpowers/scripts/tests/test_remote_skills_hook.sh
	bash skills/engineering/tdd-parallel/scripts/tests/test_preflight.sh
	bash skills/remote-agents/afk-fanout/scripts/tests/test_write_afk_entry.sh
	bash skills/remote-agents/afk-fanout/scripts/tests/test_resolve_origin_url.sh
	bash skills/remote-agents/afk-worker/scripts/tests/test_select_due_entry.sh
	bash skills/remote-agents/afk-worker/scripts/tests/test_afk_dispatch.sh

# Docs run on mkdocs-material with the `social` plugin, which needs cairo at
# build time (CI installs it via apt; macOS via `brew install cairo`). Call the
# venv's mkdocs directly, never via `uv run`/uvx: macOS strips DYLD_* when uv's
# hardened binary spawns Python, so Homebrew's cairo isn't found that way.

# Strict build — the exact gate the GitHub Pages deploy runs on push to main.
docs: .venv
	.venv/bin/mkdocs build --strict

# Live preview at http://127.0.0.1:8000 with auto-reload.
docs-serve: .venv
	.venv/bin/mkdocs serve

sync-books:
	python3 scripts/sync_book_rules.py

check-upstream-books:
	bash scripts/check_upstream_books.sh
