"""Run with streamlit run Tools/training_studio.py."""
import json
from pathlib import Path
import subprocess
import tempfile

import imageio_ffmpeg
import pandas as pd
import streamlit as st
from local_training import MATCH, STORE, ROOT, CHANNELS, aligned_video, batches, db, rows, sample_frames, train

st.set_page_config(page_title="羽球训练台", layout="wide")
st.title("羽球动作训练台")
with db() as conn:
    saved = pd.read_sql("select * from reviews order by session,original", conn)
    audit = pd.read_sql("select * from specialist_audit order by label,session,original", conn)
runs = sorted(STORE.glob("*/svm-report.json"), reverse=True)
training, review = st.tabs(["训练结果", "逐拍复核"])
with training:
    holdout = st.text_input("跨玩家测试时留出的玩家编号（空格分隔）")
    if st.button("扫描最新采集并训练"):
        try:
            with st.spinner("读取录制、按场次切分并训练…"):
                train(holdout.split() or None)
            st.rerun()
        except (ValueError, OSError, subprocess.CalledProcessError) as e:
            st.error(str(e))
    if not runs:
        st.info("先扫描并训练一次。")
        st.stop()
    run = st.selectbox("训练版本", [p.parent.name for p in runs])
    folder = STORE / run
    report = json.loads((folder / "svm-report.json").read_text())
    st.metric("留出集正确拍数", f"{report['correct']} / {report['test']}")
    st.write(f"训练 {report['train']} 拍，人工复核样本 {report['reviewed']} 拍，录像抽帧复核 {report.get('frame_reviewed', 0)} 拍。当前模型保存在本机供实验对照。")
    if "simulated_grip_correct" in report:
        st.write(f"训练集加入模拟握姿后，同一留出集正确 {report['simulated_grip_correct']} / {report['test']}。")
        st.write("有效挥拍检测", report["detector"])
    st.dataframe(pd.DataFrame({k:report["metrics"][k] for k in report["classes"]}).T)
    st.dataframe(pd.read_json(folder / "examples.json"))

@st.cache_data(max_entries=3)
def signal(session, revision):
    return sample_frames(session)

@st.cache_data(max_entries=12)
def clip(path, revision, at):
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "clip.mp4"
        subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-loglevel", "error", "-ss", str(max(0, at-1.2)),
            "-i", path, "-t", "2.4", "-an", "-vf", "scale=-2:480", "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", str(out)], check=True)
        return out.read_bytes()

with review:
    match = st.radio("数据来源", ["专项", "实战"], horizontal=True) == "实战"
    specialist = rows(folder / "review.csv")
    audit_sessions = set(audit.session)
    if match:
        sessions = sorted(p.name for p in MATCH.glob("*") if (p / "batches").is_dir())
    else:
        if not audit.empty:
            statuses = ("可用", "仅参考", "排除")
            st.write(" · ".join(f"{status} {sum(audit.status == status)}" for status in statuses))
            with st.expander("查看专项标注清单"):
                st.dataframe(audit[["label", "status", "reason", "video_s", "session"]].rename(columns={
                    "label": "采集动作", "status": "训练资格", "reason": "依据", "video_s": "录像秒数", "session": "场次",
                }), hide_index=True)
        sessions = sorted({r["session"] for r in specialist} | audit_sessions)
    session = st.selectbox("场次", sessions)
    if session is None:
        st.info("暂无可复核场次。")
        st.stop()
    if match:
        intent_file = STORE.parent / session / "发球意图复核.csv"
        if intent_file.exists():
            with st.expander("发球意图与错误阶段标注", expanded=True):
                st.dataframe(pd.read_csv(intent_file).replace({"positive":"主挥", "negative":"误触", "review":"待复核"}), hide_index=True)
    session_audit = audit[audit.session == session]
    for entry in session_audit.itertuples():
        st.info(f"{entry.label} · {entry.status}　{entry.reason}")
    if not match and any(session_audit.original < 0):
        st.stop()
    if match:
        files = list((MATCH / session / "batches").glob("*.json"))
        revision = max(p.stat().st_mtime_ns for p in files)
        events = {float(e["time"]): e.get("text", "") for b in batches(session) for e in b["events"] if e["kind"] == "candidate"}
        default_player = ""
    else:
        revision = (ROOT / session / "samples.csv").stat().st_mtime_ns
        subset = [r for r in specialist if r["session"] == session]
        events = {float(r["peak_phone_s"]): r["label"] for r in subset}
        default_player = subset[0]["participant"]
    samples = signal(session, revision)
    if len(samples) == 0:
        st.info("此场次没有运动帧。")
        st.stop()
    for r in saved[saved.session == session].itertuples():
        events.setdefault(r.original, "人工补录")
    original = st.selectbox("候选动作", [None, *sorted(events)], index=1 if events else 0,
        format_func=lambda t: "手动定位漏拍" if t is None else f"{t:.3f} 秒 · {events[t]}")
    row = saved[(saved.session == session) & (saved.original == original)] if original is not None else saved.iloc[:0]
    value = float(row.iloc[0].peak) if len(row) else (original or samples[0,0])
    peak = st.number_input("主挥峰手机时间（秒）", min_value=float(samples[0,0]), max_value=float(samples[-1,0]),
        value=float(min(max(value,samples[0,0]),samples[-1,0])), step=.01, format="%.6f", key=f"t-{session}-{original}")
    near = samples[abs(samples[:,0]-peak)<.6]
    st.line_chart(pd.DataFrame(near[:,1:], index=near[:,0]-peak, columns=CHANNELS))
    video = aligned_video(session, peak)
    if video:
        path, pts = video
        st.caption(f"摄像头 {pts:.3f} 秒 · 手机峰值位于短片第 {min(pts,1.2):.2f} 秒")
        st.video(clip(str(path), path.stat().st_mtime_ns, pts))
    else:
        st.warning("此时刻缺少同步画面。可标记排除。")
    labels = ["排除", "背景", *sorted({r["label"] for r in specialist} - {"背景"})]
    reviewed_candidate = session_audit[session_audit.original == original]
    default = row.iloc[0].label if len(row) else (
        reviewed_candidate.iloc[0].label if not reviewed_candidate.empty and reviewed_candidate.iloc[0].status == "可用" else "排除")
    if default not in labels:
        default = "排除"
    label = st.selectbox("录像复核结果", labels, index=labels.index(default), key=f"label-{session}-{original}")
    participant = st.text_input("实际玩家编号", value=row.iloc[0].participant if len(row) else default_player, key=f"p-{session}-{original}")
    reapprove = not reviewed_candidate.empty and reviewed_candidate.iloc[0].status != "可用" and label != "排除"
    confirm = st.checkbox("已重新核对录像，确认这拍可训练", key=f"confirm-{session}-{original}") if reapprove else False
    if st.button("保存逐拍标注", disabled=label != "排除" and (not participant.strip() or not video or (reapprove and not confirm))):
        with db() as conn:
            conn.execute("insert or replace into reviews values (?,?,?,?,?)",
                         (session, original if original is not None else peak, peak, label, participant.strip()))
            if confirm:
                conn.execute("update specialist_audit set status=?,reason=?,label=? where session=? and original=?",
                             ("可用", "已在训练台重新核对录像并确认。", label, session, original))
            elif not reviewed_candidate.empty and label == "排除":
                conn.execute("update specialist_audit set status=?,reason=? where session=? and original=?",
                             ("排除", "已在训练台复核并排除。", session, original))
        st.rerun()
    st.dataframe(saved)
