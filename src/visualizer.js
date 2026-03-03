import { DOM, state } from './store.js';
import { isIOS, debugLine } from './utils.js';

const MIN = 0.08;
const MAX = 0.75;
const BARS_COUNT = 11;

let audioCtx = null;
let analyser = null;
let sourceNode = null;
let dataArray = null;
let rafId = 0;
let isRunning = false;
let isInitialized = false;

// Переменные для Canvas
let ctx = null;
let canvasW = 0;
let canvasH = 0;

const useFakeVisualizer = isIOS;
const currentNoises = new Array(BARS_COUNT).fill(0);
const targetNoises = new Array(BARS_COUNT).fill(0);

// --- ИНИЦИАЛИЗАЦИЯ И РЕСАЙЗ CANVAS (с поддержкой Retina) ---
export function resizeCanvas() {
    if (!DOM.eqCanvas || !DOM.eqContainer) return;
    
    const rect = DOM.eqContainer.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    
    DOM.eqCanvas.width = rect.width * dpr;
    DOM.eqCanvas.height = rect.height * dpr;
    canvasW = rect.width;
    canvasH = rect.height;
    
    ctx = DOM.eqCanvas.getContext('2d');
    ctx.scale(dpr, dpr);
    
    // Если остановлен, перерисовать в спокойном состоянии (MIN)
    if (!isRunning) {
        drawBars(new Array(BARS_COUNT).fill(MIN));
    }
}

// --- ФУНКЦИЯ ОТРИСОВКИ АППАРАТНОГО УСКОРЕНИЯ ---
function drawBars(targets) {
    if (!ctx) return;
    
    // Очищаем предыдущий кадр
    ctx.clearRect(0, 0, canvasW, canvasH);
    ctx.fillStyle = '#000000'; // Черный цвет
    
    // Идеальный шаг для 11 столбиков без отступов
    const step = canvasW / BARS_COUNT;
    // Округляем ширину в большую сторону (Math.ceil), чтобы избежать микро-щелей сглаживания
    const barWidth = Math.ceil(step);

    for (let i = 0; i < BARS_COUNT; i++) {
        const target = targets[i];
        const barHeight = target * canvasH;
        
        // Позиция X для текущего столбика
        const x = Math.floor(i * step); 
        // Рисуем снизу вверх
        const y = canvasH - barHeight; 
        
        ctx.fillRect(x, y, barWidth, barHeight);
    }
}

function init(audioElement) {
    if (!ctx) resizeCanvas();

    if (useFakeVisualizer) {
        isInitialized = true;
        return;
    }
    if (isInitialized) {
        if (audioCtx && audioCtx.state === 'suspended') {
            audioCtx.resume();
        }
        return;
    }
    try {
        const AudioContext = window.AudioContext || window.webkitAudioContext;
        audioCtx = new AudioContext();
        
        analyser = audioCtx.createAnalyser();
        analyser.fftSize = 1024; 
        analyser.minDecibels = -85; 
        analyser.maxDecibels = -10; 
        analyser.smoothingTimeConstant = 0.85; 

        sourceNode = audioCtx.createMediaElementSource(audioElement);
        sourceNode.connect(analyser);
        analyser.connect(audioCtx.destination);

        dataArray = new Uint8Array(analyser.frequencyBinCount);
        isInitialized = true;
        debugLine('Web Audio API Initialized (Canvas Mode)');
    } catch (e) {
        console.error("Web Audio API Error:", e);
        debugLine('Web Audio API Failed', { error: e.message });
    }
}

function tick() {
    if (!isRunning) return;
    
    const targets = new Array(BARS_COUNT).fill(MIN);
    
    if (!state.isPlaying || DOM.audio.paused) {
        // Оставляем targets = MIN, канвас просто нарисует полоски внизу
    } else {
        if (useFakeVisualizer) {
            // ФЕЙК ДЛЯ iOS
            const time = Date.now();
            for (let i = 0; i < BARS_COUNT; i++) {
                if (Math.random() < 0.08) targetNoises[i] = Math.random() * 0.15;
                currentNoises[i] += (targetNoises[i] - currentNoises[i]) * 0.15;

                const speed = 150 - (i * 5);
                const wave = (Math.sin(time / speed + i * 0.5) + 1) / 2;
                let value = wave * 0.7 + currentNoises[i];

                if (i > BARS_COUNT / 2) value = value * 0.8;

                let target = MIN + value * (MAX - MIN);
                targets[i] = Math.max(MIN, Math.min(MAX, target));
            }
        } else if (analyser && dataArray) {
            // PRO ВИЗУАЛИЗАТОР
            analyser.getByteFrequencyData(dataArray);
            const minBin = 1;   
            const maxBin = 370; 
            
            for (let i = 0; i < BARS_COUNT; i++) {
                const startX = i / BARS_COUNT;
                const endX = (i + 1) / BARS_COUNT;
                
                const startIndex = Math.floor(minBin * Math.pow(maxBin / minBin, startX));
                const endIndex = Math.floor(minBin * Math.pow(maxBin / minBin, endX));
                
                let maxVal = 0;
                for (let b = startIndex; b <= Math.max(startIndex, endIndex); b++) {
                    if (dataArray[b] > maxVal) maxVal = dataArray[b];
                }
                
                let value = maxVal / 255;
                const eqBoost = 1 + (i / BARS_COUNT) * 1.4; 
                value = value * eqBoost;
                value = Math.pow(value, 1.4); 

                let target = MIN + value * (MAX - MIN);
                targets[i] = Math.max(MIN, Math.min(MAX, target));
            }
        }
    }

    // Отправляем массив высот на видеокарту
    drawBars(targets);
    rafId = requestAnimationFrame(tick);
}

export const Visualizer = {
    init,
    resizeCanvas,
    start: () => {
        if (!isRunning) {
            isRunning = true;
            if (!ctx) resizeCanvas();
            if (!useFakeVisualizer && audioCtx && audioCtx.state === 'suspended') {
                audioCtx.resume();
            }
            rafId = requestAnimationFrame(tick);
        }
    },
    stop: () => {
        isRunning = false;
        if (rafId) cancelAnimationFrame(rafId);
        // Роняем столбики в спокойное состояние
        drawBars(new Array(BARS_COUNT).fill(MIN));
    }
};