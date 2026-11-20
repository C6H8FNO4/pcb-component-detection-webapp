
const $ = id => document.getElementById(id);
const COLORS = ['#FF5252','#FFB300','#40C4FF','#FF4081','#7C4DFF','#00E676','#FF6E40','#E040FB','#18FFFF'];
let currentFile = null, lastDetections = [], MODELS = [], CURRENT = null;

/* ---------------- 模型 ---------------- */
function renderChips(m, elId) {
  const el = $(elId);
  el.innerHTML = '';
  m.classes.forEach(c => {
    const d = document.createElement('span');
    d.className = 'chip';
    d.innerHTML = `<span class="dot" style="background:${COLORS[c.index % COLORS.length]}"></span>` +
                  `<b>${c.cn || c.name}</b> · ${c.conf.toFixed(3)}`;
    el.appendChild(d);
  });
}

async function loadModels() {
  try {
    const j = await (await fetch('/api/models')).json();
    MODELS = j.models || [];
    const sel = $('modelSel');
    sel.innerHTML = '';
    if (!MODELS.length) { sel.innerHTML = '<option>models/ 里没找到模型</option>'; return; }
    MODELS.forEach(m => {
      const o = document.createElement('option');
      o.value = m.key; o.textContent = m.label;
      sel.appendChild(o);
    });
    const saved = localStorage.getItem('pcb_model');
    if (saved && MODELS.some(m => m.key === saved)) sel.value = saved;
    else if (MODELS.some(m => m.key === 'solder')) sel.value = 'solder';
    selectModel(sel.value);
  } catch (e) {
    $('modelSub').textContent = '模型列表加载失败：' + e.message;
  }
}

function selectModel(key) {
  CURRENT = MODELS.find(m => m.key === key) || MODELS[0];
  if (!CURRENT) return;
  localStorage.setItem('pcb_model', CURRENT.key);
  renderChips(CURRENT, 'chips');
  renderChips(CURRENT, 'chipsLive');
  $('modelSub').textContent = `${CURRENT.file} · imgsz ${CURRENT.imgsz} · ${CURRENT.classes.length} 类`;
  ['', 'Live'].forEach(sfx => {
    $('conf' + sfx).value = CURRENT.global_conf.toFixed(2);
    $('conf' + sfx + 'V').textContent = (+$('conf' + sfx).value).toFixed(2);
  });
  updateConfState();
}

function updateConfState() {
  const per = CURRENT && CURRENT.has_per_class_conf && $('usePerClass').checked;
  $('conf').disabled = !!per; $('confV').style.opacity = per ? .4 : 1;
  const perL = CURRENT && CURRENT.has_per_class_conf && $('usePerClassLive').checked;
  $('confLive').disabled = !!perL; $('confLiveV').style.opacity = perL ? .4 : 1;
}

$('modelSel').onchange = e => selectModel(e.target.value);
$('usePerClass').onchange = updateConfState;
$('usePerClassLive').onchange = updateConfState;
$('conf').oninput = e => $('confV').textContent = (+e.target.value).toFixed(2);
$('confLive').oninput = e => $('confLiveV').textContent = (+e.target.value).toFixed(2);
$('iou').oninput = e => $('iouV').textContent = (+e.target.value).toFixed(2);
$('iouLive').oninput = e => $('iouLiveV').textContent = (+e.target.value).toFixed(2);

/* ---------------- 标签页 ---------------- */
function showTab(which) {
  const live = which === 'live';
  $('panelSingle').classList.toggle('on', !live);
  $('panelLive').classList.toggle('on', live);
  $('tabSingle').classList.toggle('on', !live);
  $('tabLive').classList.toggle('on', live);
  if (!live) stopLive();
  else requestAnimationFrame(renderOverlay);
}
$('tabSingle').onclick = () => showTab('single');
$('tabLive').onclick = () => showTab('live');

/* ---------------- 单张 ---------------- */
function preview(file) {
  if (!file) return;
  currentFile = file;
  $('drop').innerHTML = `<img src="${URL.createObjectURL(file)}" alt="preview">`;
  $('run').disabled = false;
  $('out').innerHTML = '点击「开始检测」';
  $('summary').textContent = ''; $('table').hidden = true;
  $('meta').textContent = `${file.name} · ${(file.size/1024).toFixed(0)} KB`;
}
$('drop').onclick = () => $('file').click();
$('file').onchange = e => preview(e.target.files[0]);
['dragenter','dragover'].forEach(ev => $('drop').addEventListener(ev, e => {
  e.preventDefault(); $('drop').classList.add('over'); }));
['dragleave','drop'].forEach(ev => $('drop').addEventListener(ev, e => {
  e.preventDefault(); $('drop').classList.remove('over'); }));
$('drop').addEventListener('drop', e => { if (e.dataTransfer.files[0]) preview(e.dataTransfer.files[0]); });

$('run').onclick = async () => {
  if (!currentFile || !CURRENT) return;
  const t0 = performance.now();
  $('run').disabled = true; $('run').textContent = '检测中…';
  const fd = new FormData();
  fd.append('file', currentFile); fd.append('model', CURRENT.key);
  fd.append('iou', $('iou').value);
  if (!(CURRENT.has_per_class_conf && $('usePerClass').checked)) fd.append('conf', $('conf').value);
  try {
    const j = await (await fetch('/api/predict', { method:'POST', body:fd })).json();
    if (!j.ok) throw new Error(j.error || '服务返回错误');
    lastDetections = j.detections;
    $('out').innerHTML = `<img src="${j.image}" alt="result">`;
    $('summary').innerHTML = `<b>${j.summary}</b><span class="hint"> · ${j.model_label}` +
      ` · 原图 ${j.size.w}×${j.size.h} · 推理 ${j.ms} ms · 往返 ${Math.round(performance.now()-t0)} ms</span>`;
    const tb = $('table').querySelector('tbody');
    tb.innerHTML = j.detections.map((d,i) => `<tr>
      <td>${i+1}</td>
      <td><span class="dot" style="background:${COLORS[d.cls % COLORS.length]}"></span><span class="tag">${d.name}</span> ${d.cn}</td>
      <td class="num">${d.conf.toFixed(3)}</td>
      <td class="num">${d.xyxy[0]}</td><td class="num">${d.xyxy[1]}</td>
      <td class="num">${d.xyxy[2]}</td><td class="num">${d.xyxy[3]}</td>
      <td class="num">${d.w}×${d.h}</td></tr>`).join('');
    $('table').hidden = !j.detections.length;
    $('csv').disabled = !j.detections.length;
  } catch (err) {
    $('out').innerHTML = `<span class="err">${err.message}</span>`;
  } finally {
    $('run').disabled = false; $('run').textContent = '开始检测';
  }
};

$('csv').onclick = () => {
  const head = ['model','cls','name','cn','conf','x1','y1','x2','y2','w','h'];
  const lines = [head.join(',')].concat(lastDetections.map(d =>
    [CURRENT.key, d.cls, d.name, d.cn, d.conf, ...d.xyxy, d.w, d.h].join(',')));
  const blob = new Blob(['\ufeff' + lines.join('\n')], { type:'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = (currentFile?.name.replace(/\.[^.]+$/, '') || 'detection') + '_' + CURRENT.key + '.csv';
  a.click();
};

/* ---------------- 实时 ---------------- */
const live = { stream:null, running:false, busy:false, timer:null,
               fps:0, lastTs:0, frames:0, ms:0,
               boxes:[], sentW:0, sentH:0, maxDim:1600, grab:null };

async function startLive(kind) {
  stopLive();
  try {
    // 自测模式：用合成画面当"视频源"，不需要摄像头（验证整条链路用）
    if (kind === 'test') {
      const cv = document.createElement('canvas');
      cv.width = 1280; cv.height = 960;
      const g = cv.getContext('2d');
      let t = 0;
      const timer = setInterval(() => {
        g.fillStyle = '#0b3d1f'; g.fillRect(0, 0, 1280, 960);
        for (let i = 0; i < 60; i++) {
          g.fillStyle = '#cfdcd0';
          g.beginPath();
          g.arc(90 + (i % 10) * 118, 130 + Math.floor(i / 10) * 120, 9, 0, 6.3);
          g.fill();
        }
        g.fillStyle = '#ff5252';
        g.fillRect(120 + (t++ * 20) % 900, 700, 70, 70);
      }, 100);
      live.testTimer = timer;
      live.source = cv;
      live.grab = 'test';
      $('ph').style.display = 'none';
      live.running = true; live.frames = 0; live.fps = 0; live.lastTs = 0;
      $('btnStop').disabled = false;
      $('btnCam').disabled = true; $('btnScreen').disabled = true; $('btnTest').disabled = true;
      $('liveHint').textContent = '自测模式（合成画面，无摄像头）';
      liveLoop();
      return;
    }
    let stream;
    if (kind === 'screen') {
      stream = await navigator.mediaDevices.getDisplayMedia({
        video: { frameRate: { ideal: 15 } }, audio: false });
      live.grab = 'screen';
    } else {
      stream = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30 } },
        audio: false });
      live.grab = 'camera';
    }
    live.stream = stream;
    const v = $('video');
    v.srcObject = stream;
    v.style.display = 'block';
    $('ph').style.display = 'none';
    await v.play();

    // 用户点浏览器原生的“停止共享”时同步状态
    stream.getVideoTracks()[0].addEventListener('ended', () => stopLive());

    live.running = true; live.frames = 0; live.fps = 0; live.lastTs = 0;
    $('btnStop').disabled = false;
    $('btnCam').disabled = true; $('btnScreen').disabled = true;
    $('liveHint').textContent = kind === 'screen'
      ? '正在抓取窗口/屏幕（在共享提示条上可随时停止）'
      : '摄像头已开启';
    liveLoop();
  } catch (e) {
    $('liveHint').innerHTML = `<span class="err">打开失败：${e.message}</span>`;
    $('liveNote').textContent = '提示：摄像头/抓取窗口要求安全上下文（http://127.0.0.1 或 https）。'
      + '如果通过局域网 IP 用 http 访问，浏览器会拒绝授权。';
  }
}

function stopLive() {
  live.running = false;
  if (live.timer) { clearTimeout(live.timer); live.timer = null; }
  if (live.stream) { live.stream.getTracks().forEach(t => t.stop()); live.stream = null; }
  if (live.testTimer) { clearInterval(live.testTimer); live.testTimer = null; }
  live.source = null;
  $('video').style.display = 'none';
  $('video').srcObject = null;
  $('ph').style.display = '';
  $('btnStop').disabled = true;
  $('btnCam').disabled = false; $('btnScreen').disabled = false;
  if ($('btnTest')) $('btnTest').disabled = false;
  $('hud').textContent = '';
  $('liveHint').textContent = '';
  const c = $('overlay'); c.getContext('2d')?.clearRect(0, 0, c.width, c.height);
  $('liveSummary').textContent = '未开始';
  $('liveTable').hidden = true;
}

$('btnCam').onclick = () => startLive('camera');
$('btnScreen').onclick = () => startLive('screen');
$('btnStop').onclick = stopLive;
$('btnTest').onclick = () => startLive('test');

function liveLoop() {
  if (!live.running) return;
  if (!live.busy) captureOnce();
  live.timer = setTimeout(liveLoop, 50);   // 采集节奏；真正的瓶颈是推理
}

async function captureOnce() {
  const v = live.source || $('video');
  const vw = v.videoWidth || v.width, vh = v.videoHeight || v.height;
  if (!vw) return;
  const scale = Math.min(1, live.maxDim / Math.max(vw, vh));
  const w = Math.round(vw * scale), h = Math.round(vh * scale);
  const cv = document.createElement('canvas');
  cv.width = w; cv.height = h;
  cv.getContext('2d').drawImage(v, 0, 0, w, h);

  const blob = await new Promise(res => cv.toBlob(res, 'image/jpeg', 0.85));
  if (!blob) return;

  live.busy = true;
  const fd = new FormData();
  fd.append('file', blob, 'frame.jpg');
  fd.append('model', CURRENT.key);
  fd.append('iou', $('iouLive').value);
  if (!(CURRENT.has_per_class_conf && $('usePerClassLive').checked)) {
    fd.append('conf', $('confLive').value);
  }
  try {
    const j = await (await fetch('/api/detect', { method:'POST', body:fd })).json();
    if (j.ok) {
      live.boxes = j.detections; live.sentW = j.size.w; live.sentH = j.size.h;
      live.ms = j.ms;
      live.frames++;
      const now = performance.now();
      if (live.lastTs) {
        const inst = 1000 / Math.max(1, now - live.lastTs);
        live.fps = live.fps ? live.fps * 0.8 + inst * 0.2 : inst;
      }
      live.lastTs = now;
      updateLivePanel(j);
    }
  } catch (e) { /* 单帧失败不影响继续 */ }
  finally { live.busy = false; }
}

function updateLivePanel(j) {
  const counts = {};
  j.detections.forEach(d => { const k = d.cn || d.name; counts[k] = (counts[k] || 0) + 1; });
  const brief = Object.keys(counts).length
    ? Object.entries(counts).map(([k, v]) => `${k}×${v}`).join('  ')
    : '无缺陷';
  $('hud').textContent =
    `检测 ${live.fps.toFixed(1)} fps · 推理 ${j.ms} ms\n` +
    `帧 ${j.size.w}×${j.size.h} · 缺陷 ${j.detections.length} 个\n${brief}`;

  $('liveSummary').innerHTML = `<b>缺陷 ${j.detections.length} 个</b>` +
    `<span class="hint"> · ${CURRENT.label} · 单帧推理 ${j.ms} ms · ${live.fps.toFixed(1)} fps</span>`
    + (j.detections.length ? '<br>' + brief : '');
  const tb = $('liveTable').querySelector('tbody');
  tb.innerHTML = j.detections.map((d,i) => `<tr><td>${i+1}</td>
    <td><span class="dot" style="background:${COLORS[d.cls % COLORS.length]}"></span><span class="tag">${d.name}</span> ${d.cn}</td>
    <td class="num">${d.conf.toFixed(3)}</td></tr>`).join('');
  $('liveTable').hidden = !j.detections.length;
}

/* 叠加层：每个动画帧重画一次，框跟得上画面 */
function renderOverlay() {
  const v = $('video'), c = $('overlay');
  if ($('panelLive').classList.contains('on')) {
    const rect = v.getBoundingClientRect();
    const stage = $('stage').getBoundingClientRect();
    if (rect.width > 0) {
      const dpr = window.devicePixelRatio || 1;
      if (c.width !== Math.round(rect.width * dpr) || c.height !== Math.round(rect.height * dpr)) {
        c.width = Math.round(rect.width * dpr);
        c.height = Math.round(rect.height * dpr);
      }
      c.style.width = rect.width + 'px';
      c.style.height = rect.height + 'px';
      c.style.left = (rect.left - stage.left) + 'px';
      c.style.top = (rect.top - stage.top) + 'px';
      const ctx = c.getContext('2d');
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, rect.width, rect.height);

      if (live.sentW && live.boxes.length) {
        const sx = rect.width / live.sentW, sy = rect.height / live.sentH;
        ctx.lineWidth = 2.5;
        ctx.font = '12px ui-monospace, monospace';
        ctx.textBaseline = 'bottom';
        live.boxes.forEach(d => {
          const col = COLORS[d.cls % COLORS.length];
          const x1 = d.xyxy[0] * sx, y1 = d.xyxy[1] * sy;
          const x2 = d.xyxy[2] * sx, y2 = d.xyxy[3] * sy;
          ctx.strokeStyle = col;
          ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);
          const label = `${d.name} ${d.conf.toFixed(2)}`;
          const tw = ctx.measureText(label).width + 8;
          const ty = y1 - 2 < 14 ? y2 + 16 : y1 - 2;
          ctx.fillStyle = col;
          ctx.fillRect(x1, ty - 14, tw, 15);
          ctx.fillStyle = '#101418';
          ctx.fillText(label, x1 + 4, ty);
        });
      }
    }
  }
  requestAnimationFrame(renderOverlay);
}

$('liveNote').textContent = '说明：抓取的是当前窗口/屏幕画面，适合把显微镜、相机软件、产线画面的窗口直接丢进来检测。'
  + '推理在服务端 CPU 上跑，帧率受模型速度限制（solder@800 约 1–2 fps/核）。';

loadModels();
requestAnimationFrame(renderOverlay);

// 支持 ?tab=live 直接打开实时页；?autostart=camera|screen 自动启动（kiosk/自测用）
const qs = new URLSearchParams(location.search);
if (qs.get('tab') === 'live') showTab('live');
if (qs.get('autostart')) {
  showTab('live');
  setTimeout(() => startLive(qs.get('autostart')), 600);
}
