#!/usr/bin/env python3
"""Build AutoStop demo video (<3 min) from real deployment material.
Slides + a terminal-typing segment rendered with PIL, assembled by ffmpeg.
All hashes/addresses/prices are the real Lasna values from 2026-11-25.
"""
import os, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

OUT = "/tmp/autostop-video/frames"
os.makedirs(OUT, exist_ok=True)
W, H, FPS = 1280, 720, 24

F_BIG = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
F_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
F_MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
F_MONOB = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"

BG = (13, 17, 23); PANEL = (22, 27, 34); GREEN = (63, 185, 80)
AMBER = (210, 153, 34); WHITE = (230, 237, 243); GREY = (139, 148, 158)
BLUE = (88, 166, 255); RED = (248, 81, 73)

def font(path, size):
    return ImageFont.truetype(path, size)

def slide(title, lines, accent=GREEN, title_size=54, line_size=30, footer=None):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 10], fill=accent)
    d.text((80, 60), title, font=font(F_BIG, title_size), fill=WHITE)
    y = 170
    for ln in lines:
        if isinstance(ln, tuple):
            text, color, size = ln
        else:
            text, color, size = ln, GREY, line_size
        d.text((80, y), text, font=font(F_REG, size), fill=color)
        y += size + 22
    if footer:
        d.text((80, H - 60), footer, font=font(F_REG, 22), fill=GREY)
    return img

frames = []
def add(img, seconds):
    n = int(seconds * FPS)
    frames.append((img, n))

# --- Slide 1: title ---
img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)
d.rectangle([0, 0, W, 10], fill=GREEN)
d.text((80, 200), "AutoStop", font=font(F_BIG, 110), fill=WHITE)
d.text((80, 330), "Set it and forget it — on-chain stop-loss & take-profit",
       font=font(F_REG, 34), fill=GREEN)
d.text((80, 400), "Reactive Omni Buildathon  ·  Lasna testnet",
       font=font(F_REG, 28), fill=GREY)
d.text((80, 450), "github.com/WV629/reactive-autostop",
       font=font(F_MONO, 26), fill=BLUE)
add(img, 6)

# --- Slide 2: how it works ---
add(slide("How it works", [
    ("1.  Create an order on the vault — pair, side, amount, threshold", WHITE, 30),
    ("2.  Price moves — the pair emits a Sync event", WHITE, 30),
    ("3.  Reactive contract reacts in ~1 second, checks price vs threshold", WHITE, 30),
    ("4.  Vault re-verifies the price, swaps, and pays you out", WHITE, 30),
    ("No bot. No keeper. No browser tab left open.", GREEN, 30),
], footer="Vault: 0x452dFB22C0d999cE35A340bC8f55392Ed01143F1"), 12)

# --- Terminal segment: real logs, typed ---
TERM_LINES = [
    ("$ ./scripts/status.sh", GREEN),
    ("== balances (lREACT) ==", WHITE),
    ("reactive: 0.0684576   vault: 0.02", WHITE),
    ("reactive debt: 0   reserves: 0.16", WHITE),
    ("vault debt: 0      reserves: 0.05", WHITE),
    ("mTKN price: 2504  (0.2504 — below the 0.8000 stop)", AMBER),
    ("open orders: [0, 1]", WHITE),
    ("", WHITE),
    ("$ forge script script/Trigger.s.sol --broadcast", GREEN),
    ("price before = 4448", WHITE),
    ("price after  = 2504", AMBER),
    ("ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.", GREEN),
    ("swap 0x1f52249321b396e48cbc896eefb73d6ac3a469e7a00e87964cef8857e8f4af99", BLUE),
    ("", WHITE),
    ("$ cast logs --address $REACTIVE   # what happened next", GREEN),
    ("OrderTriggered(orderId=0, price=2504, threshold=8000)", GREEN),
    ("reactive tx 0x24715ffd05118640c6709f7a0123394bc302d278ab7717a7b057455462df9764", BLUE),
    ("block 9201315 — ONE block after the swap", WHITE),
    ("CallbackRequest -> vault, gasLimit 1,000,000", WHITE),
]
full_text = "\n".join(t for t, _ in TERM_LINES)
# chars per frame -> ~55s for the whole terminal segment
CHARS_PER_FRAME = 1
total_chars = len(full_text)
term_frames = (total_chars // CHARS_PER_FRAME) + 30
for fi in range(term_frames):
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    d.text((40, 20), "AutoStop — live on Lasna (chain 5318007)", font=font(F_MONOB, 24), fill=GREY)
    shown = full_text[: fi * CHARS_PER_FRAME]
    y = 70
    # color per line
    lines = shown.split("\n")
    for li, line in enumerate(lines):
        color = TERM_LINES[li][1] if li < len(TERM_LINES) else WHITE
        d.text((40, y), line, font=font(F_MONO, 22), fill=color)
        y += 30
    # cursor
    if fi < term_frames - 10 and lines:
        cx = 40 + len(lines[-1]) * 13
        d.rectangle([cx, y - 30, cx + 12, y - 4], fill=GREEN)
    frames.append((img, 1))

# --- Slide 3: on-chain proof ---
add(slide("On-chain proof — Lasna", [
    ("Reactive  0x67cE360Dc6B6eB82b611f17e37271D6A7b1AC4D4", WHITE, 26),
    ("Vault     0x452dFB22C0d999cE35A340bC8f55392Ed01143F1", WHITE, 26),
    ("Pair      0xAb2EeEfd147C9130BC78302F7be5607738c5436F", WHITE, 26),
    ("Order 0   stop-loss <= 0.8000  ·  Order 1  take-profit >= 1.2000", WHITE, 26),
    ("Crash swap  0x2fd87f60...  block 9200663  (price 1.0000 -> 0.4448)", BLUE, 26),
    ("Reactive tx 0x9508e39e...  block 9200664  (1 block later)", BLUE, 26),
    ("lasna.reactscan.net", GREY, 26),
]), 12)

# --- Slide 4: local full loop ---
add(slide("Full loop proven locally", [
    ("forge test — 8/8 passed", GREEN, 34),
    ("testStopLossFullLoop       — order created, price crashed,", WHITE, 28),
    ("                             callback fired, order executed, payout sent", WHITE, 28),
    ("testTakeProfitFullLoop     — same loop on the upside", WHITE, 28),
    ("testStaleTriggerDoesNotSell — vault re-verifies price first", WHITE, 28),
    ("MockSystem delivers the callback synchronously in-test;", GREY, 28),
    ("on Lasna the same callback waits on the network relay.", GREY, 28),
]), 12)

# --- Slide 5: honest status ---
add(slide("Status — 2026-11-25", [
    ("Reaction: PROVEN live on Lasna (official Reactive MCP: REACTED).", GREEN, 30),
    ("Callback: PENDING — Lasna relay is not posting results", AMBER, 30),
    ("network-wide (no CallbackPosted in the last 30,000 blocks).", AMBER, 30),
    ("Contracts, funding, subscription & request all verified correct.", WHITE, 30),
    ("Next: re-run the trigger when the relay recovers; the loop", WHITE, 30),
    ("completes with zero code changes.", WHITE, 30),
], accent=AMBER, footer="github.com/WV629/reactive-autostop  ·  DoraHacks: wvllm"), 12)

# --- write frames ---
idx = 0
for img, n in frames:
    for _ in range(n):
        idx += 1
        img.save(os.path.join(OUT, f"frame_{idx:05d}.png"))
total = idx / FPS
print(f"frames={idx} duration={total:.1f}s")
assert total < 180, "video too long"
# --- assemble ---
mp4 = "/home/hatch/workspace/hackathons/reactive-omni/demo-video/autostop-demo.mp4"
os.makedirs(os.path.dirname(mp4), exist_ok=True)
subprocess.run([
    "ffmpeg", "-y", "-framerate", str(FPS), "-i", os.path.join(OUT, "frame_%05d.png"),
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-movflags", "+faststart", mp4
], check=True, capture_output=True)
print("wrote", mp4, os.path.getsize(mp4), "bytes")
