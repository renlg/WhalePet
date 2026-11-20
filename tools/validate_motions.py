#!/usr/bin/env python3
"""严格校验 Live2D motion3.json / exp3.json 是否符合 Cubism 3 规范。

用法:
  python3 tools/validate_motions.py                 # 校验 model/motions + model/expressions 全部
  python3 tools/validate_motions.py <file...>        # 只校验指定文件

判据 (Cubism Motion3 规范):
  Segments 数组: [t0, v0, <seg>...]
  每个 <seg> 以类型开头:
    0 = Linear  -> type, time, value              (3 个数)
    1 = Bezier  -> type, time, value, c1t, c1v, c2t, c2v   (7 个数)
    2 = Stepped -> type, time, value              (3 个数)
    3 = InverseStepped -> type, time, value       (3 个数)
  - 时间必须非递减, 且在 [0, Meta.Duration] 内
  - 解析结束后必须正好消费完整个数组（多/少一个数都算错）
  - Curve 的 Id 必须是模型真实存在的参数 (从 cdi3 + 现有 motion 出现过的参数集合推断)

⚠️ 常见错误：把 Segments 写成裸 time/value 对 (如 [0,10,0.55,12,...])。
   Cubism 运行时会静默忽略该曲线（动作不生效但不报错）——本脚本会直接报错。
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOTION_DIR = os.path.join(ROOT, "model", "motions")
EXPR_DIR = os.path.join(ROOT, "model", "expressions")
CDI = os.path.join(ROOT, "model", "c_0120.cdi3.json")

SEG_LEN = {0: 3, 1: 7, 2: 3, 3: 3}


def known_params():
    ids = set()
    try:
        cdi = json.load(open(CDI, encoding="utf-8"))
        for p in cdi.get("Parameters", []):
            ids.add(p["Id"])
    except Exception as e:  # pragma: no cover
        print(f"WARN: 无法读取 cdi3 ({e})，参数名不做校验")
        return None
    # cdi3 不含所有参数, 用现有 motion 里出现过的 Id 补充
    for name in os.listdir(MOTION_DIR):
        if not name.endswith(".motion3.json"):
            continue
        try:
            d = json.load(open(os.path.join(MOTION_DIR, name), encoding="utf-8"))
            for c in d.get("Curves", []):
                if c.get("Target") == "Parameter":
                    ids.add(c["Id"])
        except Exception:
            pass
    return ids


def check_motion(path, params):
    errs, warns = [], []
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        return [f"JSON 解析失败: {e}"], warns
    if d.get("Version") != 3:
        warns.append(f"Version={d.get('Version')} (非 3)")
    meta = d.get("Meta", {})
    dur = meta.get("Duration")
    if not isinstance(dur, (int, float)) or dur <= 0:
        errs.append(f"Meta.Duration 非法: {dur!r}")
        dur = 0.0
    if not isinstance(meta.get("Loop"), bool):
        errs.append("Meta.Loop 必须为布尔")
    curves = d.get("Curves", [])
    if not curves:
        errs.append("没有 Curves")
    if meta.get("CurveCount") not in (None, len(curves)):
        errs.append(f"Meta.CurveCount={meta.get('CurveCount')} 实际={len(curves)}")
    if meta.get("Fps") not in (None, 30, 30.0, 60, 60.0):
        warns.append(f"Meta.Fps={meta.get('Fps')}")

    total_segs = 0
    for idx, c in enumerate(curves):
        cid = c.get("Id", f"#{idx}")
        if c.get("Target") not in ("Parameter", "Model"):
            errs.append(f"[{cid}] Target 非法: {c.get('Target')!r}")
        if c.get("Target") == "Parameter" and params is not None and cid not in params:
            errs.append(f"[{cid}] 参数在模型中不存在 (拼错就不会动)")
        s = c.get("Segments")
        if not isinstance(s, list) or len(s) < 2:
            errs.append(f"[{cid}] Segments 缺失/过短")
            continue
        if any(not isinstance(v, (int, float)) for v in s):
            errs.append(f"[{cid}] Segments 含非数字")
            continue
        t_prev, v_prev = s[0], s[1]
        if not (0 <= t_prev <= dur + 1e-6):
            errs.append(f"[{cid}] 首点时间 {t_prev} 越界 [0,{dur}]")
        i, segs = 2, 0
        while i < len(s):
            t = s[i]
            if t not in (0, 1, 2, 3):
                errs.append(
                    f"[{cid}] 位置 {i} 段类型非法: {t!r} "
                    f"(疑似写成裸 time/value 对，Cubism 会静默忽略该曲线)"
                )
                break
            need = SEG_LEN[int(t)]
            if i + need > len(s):
                errs.append(f"[{cid}] 位置 {i} 段被截断 (类型 {int(t)} 需 {need} 个数)")
                break
            tt, vv = s[i + 1], s[i + 2]
            if tt < t_prev - 1e-9:
                errs.append(f"[{cid}] 时间倒退 {t_prev} -> {tt}")
            if not (0 <= tt <= dur + 1e-6):
                errs.append(f"[{cid}] 时间 {tt} 越界 [0,{dur}]")
            t_prev = tt
            i += need
            segs += 1
        else:
            total_segs += segs
        if i != len(s):
            errs.append(f"[{cid}] Segments 未正好消费完 (剩余 {len(s) - i} 个数)")
    if meta.get("TotalSegmentCount") not in (None, total_segs):
        errs.append(f"Meta.TotalSegmentCount={meta.get('TotalSegmentCount')} 实际={total_segs}")
    return errs, warns


BLENDS = {"Add", "Multiply", "Overwrite", None}


def check_expression(path, params):
    errs = []
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        return [f"JSON 解析失败: {e}"], []
    if d.get("Type") != "Live2D Expression":
        errs.append(f"Type 必须是 'Live2D Expression', 实际 {d.get('Type')!r}")
    ps = d.get("Parameters")
    if not isinstance(ps, list) or not ps:
        errs.append("Parameters 缺失/为空")
        return errs, []
    for p in ps:
        pid = p.get("Id")
        if params is not None and pid not in params:
            errs.append(f"[{pid}] 参数在模型中不存在")
        if p.get("Blend") not in BLENDS:
            errs.append(f"[{pid}] Blend 非法: {p.get('Blend')!r}")
        if not isinstance(p.get("Value"), (int, float)):
            errs.append(f"[{pid}] Value 必须为数字")
    return errs, []


def main(argv):
    params = known_params()
    if params is not None:
        print(f"模型参数集合: {len(params)} 个")
    targets = argv[1:] or (
        [os.path.join(MOTION_DIR, f) for f in sorted(os.listdir(MOTION_DIR)) if f.endswith(".motion3.json")]
        + [os.path.join(EXPR_DIR, f) for f in sorted(os.listdir(EXPR_DIR)) if f.endswith(".exp3.json")]
    )
    failed = 0
    for path in targets:
        is_expr = path.endswith(".exp3.json")
        errs, warns = (check_expression if is_expr else check_motion)(path, params)
        name = os.path.basename(path)
        if errs:
            failed += 1
            print(f"❌ {name}")
            for e in errs:
                print(f"    - {e}")
        else:
            note = ("  " + "; ".join(warns)) if warns else ""
            if not is_expr:
                d = json.load(open(path, encoding="utf-8"))
                print(f"✅ {name}  dur={d['Meta']['Duration']}s curves={len(d['Curves'])}"
                      f" loop={d['Meta'].get('Loop')}{note}")
    print(f"\n结果: {len(targets) - failed}/{len(targets)} 通过")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
