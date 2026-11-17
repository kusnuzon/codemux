---
managed-by: codemux skills module
name: webapp-testing
description: Test a local web application end-to-end with Python Playwright (zplaywright build) in headless Chromium on Termux — launch, interact, screenshot, assert, capture console errors. Use when the user asks to verify a web UI, smoke-test a Flask/Node page, reproduce a UI bug with a screenshot, or automate a browser against a local server.
---

# webapp-testing (Termux / zplaywright edition)

End-to-end browser tests on Android use Python Playwright patched by
[zplaywright](https://github.com/kusnuzon/zplaywright) driving the Termux
Chromium. The official Playwright and any Node-based runner do not work on
`android-arm64` — do not use them (see the agent-browser skill for details).

## Setup

```bash
pip install pyee
curl -sL "https://raw.githubusercontent.com/kusnuzon/zplaywright/main/install.sh" | bash
pkg install chromium    # needs: pkg install x11-repo
python -c "import playwright" && echo ok
```

## Smoke-test template

```python
import asyncio
from playwright.async_api import async_playwright

URL = "http://127.0.0.1:5000/"          # your local dev server

async def main():
    errors = []
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            executable_path="/data/data/com.termux/files/usr/bin/chromium-browser",
            headless=True,
            args=["--no-sandbox", "--disable-gpu"],
        )
        page = await browser.new_page(viewport={"width": 700, "height": 1400})
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))

        await page.goto(URL, wait_until="load", timeout=30000)
        assert await page.title(), "page has a title"
        await page.screenshot(path="shot.png", full_page=True)

        # interact: fill a form and submit
        # await page.fill("#name", "test")
        # await page.click("text=Save")
        # assert "saved" in (await page.inner_text("body")).lower()

        if errors:
            print("CONSOLE ERRORS:", *errors, sep="\n  ")
        else:
            print("no console errors")
        await browser.close()

asyncio.run(main())
```

## Checklist for a UI bug report

1. Reproduce with the template above and save a screenshot.
2. Capture console errors and failed requests
   (`page.on("requestfailed", ...)`).
3. Measure instead of guessing: `await page.locator(sel).bounding_box()` for
   geometry claims (alignment, overlap, visibility).
4. Fix, re-run the script, and confirm the new screenshot + empty error list.

## Termux gotchas

- No `/tmp` — use `$PREFIX/tmp` for temp files.
- Start the dev server in a tmux window (`tmux new-session -d -s web 'python app.py'`)
  so tests do not block the terminal.
- Screenshots the agent inspects must be inside the project folder (`~/shots/`);
  copy keepers to `/storage/emulated/0/Music/SS/`.
- If the page needs a mobile layout, set a mobile user agent on `new_page`.
