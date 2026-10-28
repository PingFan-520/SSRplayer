# -*- coding: utf-8 -*-
"""一键生成 docs/作品报告_音乐相框.docx：
   模板副本 -> 清空正文 -> 分段写 markdown + 插图 -> 拆图段 -> 排版 -> 保存 -> 修 Normal 对齐。"""
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile

SKILL = r"E:/workbuddy/resources/app.asar.unpacked/resources/plugins/workbuddy-builtin/skills/workbuddy-local-office-edit"
EDS = os.path.join(SKILL, "edsdk.py")
BASE = "D:/Work/fpga/yuanshen/docs"
DOC = f"{BASE}/作品报告_音乐相框.docx"
TPL = "C:/Users/28966/Desktop/作品报告（模板）.docx"


def call(tool, **kw):
    kw.setdefault("file_id", DOC)
    p = subprocess.run([sys.executable, EDS, "call", tool, "--json",
                        json.dumps(kw, ensure_ascii=False)],
                       cwd=SKILL, capture_output=True, text=True, encoding="utf-8")
    for line in reversed((p.stdout or "").strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except Exception:
                pass
    return {"ok": False, "raw": (p.stdout or "")[-400:]}


def ok(r):
    return r.get("ok", True) and r.get("error") is None


def struct():
    return call("doc_resolve_document_structure", mode="compact", text_preview_length=30)


shutil.copyfile(TPL, DOC)
print(call("open_file", file_path=DOC).get("message", "opened"))

# ---------------- 1. 清空正文 ----------------
nodes = [n for n in struct()["nodes"] if n.get("type") != "Table"]
starts = [n["start_index"] for n in nodes]
print("模板段落", len(starts))
bad = 0
for s in reversed(starts[1:]):
    if not ok(call("doc_delete_paragraph", idx=s)):
        bad += 1
print("删除失败", bad)
print(call("doc_replace_text", ranges=[{"begin": 0, "end": 4}], text="").get("message"))

# ---------------- 2. 写正文 + 插图 ----------------
figs = [("fig1_flow.png", 550, 238), ("fig2_arch.png", 550, 358),
        ("fig3_pipe.png", 550, 222), ("fig4_fsm.png", 550, 266)]
pos = 0
for i in range(1, 6):
    r = call("doc_insert_markdown", idx=pos,
             markdown="file://" + f"{BASE}/report_p{i}.md")
    if not ok(r):
        print("md FAIL", i, r)
        sys.exit(1)
    pos = r.get("position", pos)
    print(f"p{i} ok -> {pos}")
    if i <= 4:
        png, w, h = figs[i - 1]
        r = call("doc_insert_image", idx=pos, image_path=f"{BASE}/fig/{png}", w=w, h=h)
        if not ok(r):
            print("img FAIL", png, r)
            sys.exit(1)
        pos = r.get("position", pos)
        print(f"   {png} -> {pos}")

# ---------------- 3. 图片独立成段 ----------------
imgs = call("doc_get_images").get("images", [])
body_imgs = [im["index"] for im in imgs if im["index"] < 20000]
for idx in sorted(body_imgs, reverse=True):
    r = call("doc_insert_paragraph", idx=idx + 1)
    print("split", idx, ok(r))

# ---------------- 4. 段落排版 ----------------
d = struct()
rs, img_rs = [], []
for n in d["nodes"]:
    if n.get("type") != "Paragraph":
        continue
    t = n.get("text_preview") or ""
    (img_rs if "[Image]" in t else rs).append(
        {"begin": n["start_index"], "end": n["end_index"]})
print("正文段", len(rs), "图段", len(img_rs))
print(call("doc_modify_paragraph", ranges=rs, jc="both",
           first_line_indent_chars=2).get("message"))
for r0 in img_rs:
    call("doc_modify_paragraph", ranges=[r0], jc="center")
    call("doc_modify_paragraph", ranges=[r0], first_line_indent_chars=0)
print("图段居中完成")

# ---------------- 5. 副标题 ----------------
d = struct()
for n in d["nodes"]:
    if (n.get("text_preview") or "").startswith("—— 基于"):
        b, e = n["start_index"], n["end_index"]
        call("doc_modify_paragraph", ranges=[{"begin": b, "end": e}],
             jc="center", paragraph_style="Normal")
        call("doc_modify_paragraph", ranges=[{"begin": b, "end": e}],
             first_line_indent_chars=0)
        call("doc_update_text_property", ranges=[{"begin": b, "end": e}],
             format={"font_family": "楷体", "font_size": 13, "bold": False})
        print("副标题 ok")

# ---------------- 6. 命名样式 ----------------
STY = [("NORMAL_TEXT", {"line_spacing": 1.5, "line_spacing_rule": 1,
                        "spacing_before": 0, "spacing_after": 3},
        {"font_family": "宋体", "font_size": 12}),
       ("HEADING_1", {"jc": "center", "spacing_before": 0, "spacing_after": 10,
                      "line_spacing": 1.3, "line_spacing_rule": 1},
        {"font_family": "黑体", "font_size": 20, "bold": True, "color": "000000"}),
       ("HEADING_2", {"jc": "center", "spacing_before": 16, "spacing_after": 10,
                      "line_spacing": 1.3, "line_spacing_rule": 1},
        {"font_family": "黑体", "font_size": 15, "bold": True, "color": "000000"}),
       ("HEADING_3", {"jc": "left", "spacing_before": 12, "spacing_after": 6,
                      "line_spacing": 1.4, "line_spacing_rule": 1},
        {"font_family": "黑体", "font_size": 13, "bold": True, "color": "000000"}),
       ("HEADING_4", {"jc": "left", "spacing_before": 8, "spacing_after": 4,
                      "line_spacing": 1.4, "line_spacing_rule": 1},
        {"font_family": "黑体", "font_size": 12, "bold": True, "color": "000000"})]
for k, p, t in STY:
    print(k, ok(call("doc_update_named_style", named_style_type=k,
                     paragraph_style=p, text_style=t)))

print(call("save_file").get("message", "saved"))
call("close_file")

# ---------------- 7. 修 Normal 的 jc（工具不认 jc=both）----------------
tmp = DOC + ".tmp"
zin = zipfile.ZipFile(DOC)
zout = zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED)
patched = False
for item in zin.infolist():
    data = zin.read(item.filename)
    if item.filename == "word/styles.xml":
        s = data.decode("utf-8")
        m = re.search(r'(<w:style [^>]*w:styleName="Normal".*?)(</w:style>)', s, re.S)
        if not m:
            m = re.search(r'(<w:style [^>]*w:styleId="000011".*?)(</w:style>)', s, re.S)
        if m and '<w:jc w:val="end"/>' in m.group(1):
            blk = m.group(1).replace('<w:jc w:val="end"/>', '<w:jc w:val="both"/>')
            s = s[:m.start(1)] + blk + s[m.end(1):]
            patched = True
        data = s.encode("utf-8")
    zout.writestr(item, data)
zout.close()
zin.close()
shutil.move(tmp, DOC)
print("Normal jc ->both:", patched)
print("BUILD DONE")
