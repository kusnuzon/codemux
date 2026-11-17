---
managed-by: codemux skills module
name: agent-browser
description: Drive a real Chromium browser from Termux with Python Playwright (zplaywright build) — open pages, read text, fill forms, click, evaluate JS, and take screenshots. Use when the user asks to open a URL, verify how a web page renders, fill or submit a form, capture a screenshot of a site, or script browser interactions on Android/Termux.
---

# agent-browser (Termux / zplaywright edition)

Browser automation on Android **must** go through Python Playwright patched by
[zplaywright](https://github.com/kusnuzon/zplaywright). The official Playwright
does not support `android-arm64` (`Error: Unsupported platform`), the Node CLI
`agent-browser` has no native Android binary, and `playwright install` always
fails on Android. Do not try any of those.

## One-time setup (or run `codemux install --skip ...` — the codemux `skills`
## module does all of this)

```bash
pip install pyee                       # event emitter needed by the patcher
curl -sL "https://raw.githubusercontent.com/kusnuzon/zplaywright/main/install.sh" | bash
curl -sO "https://raw.githubusercontent.com/kusnuzon/zplaywright/main/tes.py"
python tes.py                          # must print: Example Domain
pkg install chromium                   # needs the x11 repo: pkg install x11-repo
```

## Launch configuration (always required)

```python
from playwright.async_api import async_playwright

browser = await p.chromium.launch(
    executable_path="/data/data/com.termux/files/usr/bin/chromium-browser",
    headless=True,
    args=["--no-sandbox", "--disable-gpu"],
)
```

## Recipes

```python
page = await browser.new_page(user_agent=UA, viewport={"width": 700, "height": 1400})
await page.goto(URL, wait_until="load", timeout=60000)
await page.wait_for_timeout(5000)          # let JS-heavy pages settle
text = await page.inner_text("body")       # read the page
await page.screenshot(path="shot.png")     # or full_page=True
await page.fill("#field", "value")         # form input
await page.get_by_text("Sign in").first.click()
result = await page.evaluate("document.title")
```

Run scripts with `python3 script.py` (use `asyncio.run(main())`).

## Termux gotchas

- There is no `/tmp` — write temp files to `$PREFIX/tmp`.
- Screenshots for the agent to inspect must live inside the project folder
  (e.g. `~/shots/`); copy them to `/storage/emulated/0/Music/SS/` afterwards.
- JS-heavy pages often nest an inner iframe: probe
  `for f in page.frames: print(f.url, await f.locator("input").count())` and
  interact with the frame whose URL matches the content host, not the top page.
- Sites behind Cloudflare challenge pages block headless visits: fetch the page
  HTML with curl (mobile UA), extract the real content iframe/origin URL, and
  open that URL directly with a mobile Chrome user agent.
- If a daemon-less run hangs, kill stale chromium processes:
  `pkill -f chromium-browser` (careful: can match your own shell's command line).
