# AIGC START
"""Hikvision InputProxy channel batch rename GUI."""
from __future__ import annotations

import re
import threading
import time
import tkinter as tk
import urllib.error
import urllib.request
from http.cookiejar import CookieJar
from tkinter import messagebox, ttk
from urllib.parse import urlparse
from xml.sax.saxutils import escape as xml_escape

IP_RE = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")
CHANNEL_RE = re.compile(r"^[Dd](\d+)$")


def normalize_base_url(text: str) -> tuple[str, str]:
    """Return (base_url without trailing slash, host)."""
    raw = text.strip()
    if not raw:
        raise ValueError("浏览器地址不能为空")
    if "://" not in raw:
        raw = "http://" + raw
    parsed = urlparse(raw)
    if not parsed.hostname:
        raise ValueError("浏览器地址无效")
    base = f"{parsed.scheme}://{parsed.hostname}"
    if parsed.port:
        base += f":{parsed.port}"
    return base, parsed.hostname


def parse_name_list(text: str) -> list[tuple[int, str]]:
    """
    支持多种粘贴格式：
    1) 平台IP D40 摄像头IP 名称…（空格分隔，名称可含空格）
    2) Excel 复制：平台IP\\tD40\\t摄像头IP\\t名称
    3) 旧格式：37,新名称  或  D37,新名称
    """
    items: list[tuple[int, str]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("通道号") or line.startswith("改名名单"):
            continue

        # Excel 制表符
        if "\t" in line:
            cols = [c.strip() for c in line.split("\t") if c.strip() != ""]
            channel_id = None
            name = ""
            for i, col in enumerate(cols):
                m = CHANNEL_RE.fullmatch(col)
                if m:
                    channel_id = int(m.group(1))
                    # 通道后若是摄像头 IP，则名称从再后面开始；否则后面全是名称
                    rest = cols[i + 1 :]
                    if rest and IP_RE.fullmatch(rest[0]):
                        name = " ".join(rest[1:]).strip()
                    else:
                        name = " ".join(rest).strip()
                    break
                if col.isdigit() and channel_id is None and i == 0 and len(cols) >= 2:
                    # 纯数字通道号在第一列
                    channel_id = int(col)
                    name = " ".join(cols[1:]).strip()
                    break
            if channel_id is not None and name:
                items.append((channel_id, name))
            continue

        # 逗号格式：37,名称 / D37,名称
        if "," in line or "，" in line:
            parts = re.split(r"[,，]", line, maxsplit=1)
            if len(parts) == 2:
                id_text = parts[0].strip()
                name = parts[1].strip()
                m = CHANNEL_RE.fullmatch(id_text)
                if m:
                    items.append((int(m.group(1)), name))
                    continue
                if id_text.isdigit() and name:
                    items.append((int(id_text), name))
                    continue

        # 空格格式：192.168.22.252 D40 192.168.22.238 负 2 层停车场
        tokens = line.split()
        for i, tok in enumerate(tokens):
            m = CHANNEL_RE.fullmatch(tok)
            if not m:
                continue
            channel_id = int(m.group(1))
            rest = tokens[i + 1 :]
            if rest and IP_RE.fullmatch(rest[0]):
                name = " ".join(rest[1:]).strip()
            else:
                name = " ".join(rest).strip()
            if name:
                items.append((channel_id, name))
            break

    return items


def replace_name_in_xml(xml_text: str, new_name: str) -> str:
    if not re.search(r"<name>[^<]*</name>", xml_text):
        raise ValueError("响应里找不到 <name> 节点")
    safe = xml_escape(new_name)
    return re.sub(r"<name>[^<]*</name>", f"<name>{safe}</name>", xml_text, count=1)


class ChannelRenamer:
    def __init__(
        self,
        base_url: str,
        host: str,
        cookie_name: str,
        cookie_value: str,
        session_tag: str,
    ):
        self.base_url = base_url.rstrip("/")
        self.host = host
        self.cookie_name = cookie_name.strip()
        self.cookie_value = cookie_value.strip()
        self.session_tag = session_tag.strip()
        self.jar = CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.jar)
        )

    def _headers(self, content_type: str | None = None) -> dict[str, str]:
        headers = {
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Origin": self.base_url,
            "Referer": f"{self.base_url}/doc/index.html",
            "SessionTag": self.session_tag,
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/152.0.0.0 Safari/537.36"
            ),
            "Cookie": (
                f"updatePlugin=false; downloadTips=false; "
                f"{self.cookie_name}={self.cookie_value}"
            ),
        }
        if content_type:
            headers["Content-Type"] = content_type
        return headers

    def get_channel_xml(self, channel_id: int) -> str:
        url = f"{self.base_url}/ISAPI/ContentMgmt/InputProxy/channels/{channel_id}"
        req = urllib.request.Request(url, headers=self._headers(), method="GET")
        with self.opener.open(req, timeout=30) as resp:
            return resp.read().decode("utf-8", errors="replace")

    def put_channel_xml(self, channel_id: int, xml: str) -> int:
        url = f"{self.base_url}/ISAPI/ContentMgmt/InputProxy/channels/{channel_id}"
        data = xml.encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers=self._headers('application/xml; charset="UTF-8"'),
            method="PUT",
        )
        with self.opener.open(req, timeout=30) as resp:
            return getattr(resp, "status", 200)


class App(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("海康监控通道批量改名")
        self.geometry("820x740")
        self.minsize(720, 640)
        self.running = False

        pad = {"padx": 12, "pady": 4}
        frm = ttk.Frame(self)
        frm.pack(fill=tk.BOTH, expand=True, **pad)

        tip = (
            "1. 填写下方「浏览器地址」（例如 192.168.22.252 或 192.168.22.253）并先在浏览器登录\n"
            "2. F12 → 应用程序 → Cookies → 复制 WebSession_ 的名称和值\n"
            "3. Network 任意请求 Headers 里复制 SessionTag\n"
            "4. 从 Excel 直接复制粘贴名单到下面文本框（不要用 CSV）"
        )
        ttk.Label(frm, text=tip, justify=tk.LEFT).pack(anchor="w", pady=(0, 8))

        row0 = ttk.Frame(frm)
        row0.pack(fill=tk.X, pady=2)
        ttk.Label(row0, text="浏览器地址", width=12).pack(side=tk.LEFT)
        self.base_url_var = tk.StringVar(value="http://192.168.22.252")
        ttk.Entry(row0, textvariable=self.base_url_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        row1 = ttk.Frame(frm)
        row1.pack(fill=tk.X, pady=2)
        ttk.Label(row1, text="Cookie 名称", width=12).pack(side=tk.LEFT)
        self.cookie_name = tk.StringVar(value="WebSession_4520699070")
        ttk.Entry(row1, textvariable=self.cookie_name).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        row2 = ttk.Frame(frm)
        row2.pack(fill=tk.X, pady=2)
        ttk.Label(row2, text="Cookie 值", width=12).pack(side=tk.LEFT)
        self.cookie_value = tk.StringVar()
        ttk.Entry(row2, textvariable=self.cookie_value).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        row3 = ttk.Frame(frm)
        row3.pack(fill=tk.X, pady=2)
        ttk.Label(row3, text="SessionTag", width=12).pack(side=tk.LEFT)
        self.session_tag = tk.StringVar()
        ttk.Entry(row3, textvariable=self.session_tag).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )

        ttk.Label(
            frm,
            text="改名名单（从 Excel 复制粘贴；格式：平台IP  通道号  摄像头IP  名称）",
        ).pack(anchor="w", pady=(10, 2))
        self.names = tk.Text(frm, height=14, font=("Consolas", 10))
        self.names.pack(fill=tk.BOTH, expand=False)
        self.names.insert(
            "1.0",
            "192.168.22.252 D40 192.168.22.238 负 2 层停车场\n"
            "192.168.22.252 D41 192.168.22.237 负 2 层停车场14\n",
        )

        btns = ttk.Frame(frm)
        btns.pack(fill=tk.X, pady=8)
        ttk.Button(btns, text="清空名单", command=self.clear_names).pack(side=tk.LEFT)
        ttk.Button(btns, text="检查名单", command=self.preview_names).pack(
            side=tk.LEFT, padx=8
        )
        self.dry_run = tk.BooleanVar(value=True)
        ttk.Checkbutton(btns, text="只演练，不真正改名", variable=self.dry_run).pack(
            side=tk.LEFT, padx=16
        )
        self.start_btn = ttk.Button(btns, text="开始改名", command=self.start)
        self.start_btn.pack(side=tk.RIGHT)

        ttk.Label(frm, text="运行日志").pack(anchor="w")
        self.log = tk.Text(
            frm, height=12, font=("Consolas", 9), bg="#1e1e1e", fg="#dddddd"
        )
        self.log.pack(fill=tk.BOTH, expand=True)
        self.log.configure(state=tk.DISABLED)

    def clear_names(self) -> None:
        self.names.delete("1.0", tk.END)

    def preview_names(self) -> None:
        items = parse_name_list(self.names.get("1.0", tk.END))
        if not items:
            messagebox.showwarning("检查名单", "没有解析到有效行。请确认是：平台IP D号 摄像头IP 名称")
            return
        preview = "\n".join(f"D{cid} → {name}" for cid, name in items[:20])
        more = "" if len(items) <= 20 else f"\n… 还有 {len(items) - 20} 条"
        messagebox.showinfo("检查名单", f"共解析到 {len(items)} 条：\n\n{preview}{more}")

    def append_log(self, msg: str) -> None:
        def _do() -> None:
            self.log.configure(state=tk.NORMAL)
            self.log.insert(tk.END, msg + "\n")
            self.log.see(tk.END)
            self.log.configure(state=tk.DISABLED)

        self.after(0, _do)

    def start(self) -> None:
        if self.running:
            return
        try:
            base_url, host = normalize_base_url(self.base_url_var.get())
        except ValueError as exc:
            messagebox.showwarning("浏览器地址", str(exc))
            return

        cookie_name = self.cookie_name.get().strip()
        cookie_value = self.cookie_value.get().strip()
        session_tag = self.session_tag.get().strip()
        items = parse_name_list(self.names.get("1.0", tk.END))
        dry_run = self.dry_run.get()

        if not cookie_name or not cookie_value or not session_tag:
            messagebox.showwarning("缺少信息", "请填写 Cookie 名称、Cookie 值、SessionTag")
            return
        if not items:
            messagebox.showwarning(
                "缺少名单",
                "没有解析到名单。请从 Excel 粘贴，格式：\n"
                "192.168.22.252 D40 192.168.22.238 负 2 层停车场",
            )
            return

        self.running = True
        self.start_btn.configure(state=tk.DISABLED)
        self.append_log(
            f"目标平台：{base_url} ，共 {len(items)} 条，模式："
            f"{'只演练' if dry_run else '真正改名'}"
        )

        def worker() -> None:
            ok = skip = fail = 0
            try:
                client = ChannelRenamer(
                    base_url, host, cookie_name, cookie_value, session_tag
                )
                for channel_id, new_name in items:
                    self.append_log(f"通道 D{channel_id} → {new_name}")
                    try:
                        xml = client.get_channel_xml(channel_id)
                        m = re.search(r"<name>([^<]*)</name>", xml)
                        old_name = m.group(1) if m else None
                        self.append_log(f"  当前：{old_name}")
                        if old_name == new_name:
                            self.append_log("  已是目标名，跳过")
                            skip += 1
                            time.sleep(0.4)
                            continue
                        new_xml = replace_name_in_xml(xml, new_name)
                        if dry_run:
                            self.append_log("  [演练] 不会写入")
                            ok += 1
                        else:
                            status = client.put_channel_xml(channel_id, new_xml)
                            self.append_log(f"  成功 HTTP {status}")
                            ok += 1
                    except urllib.error.HTTPError as exc:
                        body = exc.read().decode("utf-8", errors="replace")[:200]
                        self.append_log(f"  失败 HTTP {exc.code}: {body}")
                        fail += 1
                    except Exception as exc:  # noqa: BLE001
                        self.append_log(f"  失败：{exc}")
                        fail += 1
                    time.sleep(0.8)
                self.append_log(f"完成：成功/演练 {ok}，跳过 {skip}，失败 {fail}")
                if fail:
                    self.append_log(
                        "若大量失败：确认浏览器地址正确，并重新复制最新 Cookie / SessionTag"
                    )
            finally:

                def done() -> None:
                    self.running = False
                    self.start_btn.configure(state=tk.NORMAL)

                self.after(0, done)

        threading.Thread(target=worker, daemon=True).start()


def main() -> None:
    app = App()
    app.mainloop()


if __name__ == "__main__":
    main()
# AIGC END
