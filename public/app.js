'use strict';

const $ = (id) => document.getElementById(id);
const state = { symbol: 'AAPL', range: '1d', mode: 'line', data: null, request: 0 };
let chart, lineSeries, candleSeries, volumeSeries, suggestions = [], chosen = -1;
let searchController = null, searchTimer = null;

function formatNumber(value, digits = 2) {
  return new Intl.NumberFormat('pl-PL', {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
}
function formatVolume(value) {
  if (value >= 1e9) return `${formatNumber(value / 1e9, 2)} mld`;
  if (value >= 1e6) return `${formatNumber(value / 1e6, 2)} mln`;
  if (value >= 1e3) return `${formatNumber(value / 1e3, 1)} tys.`;
  return formatNumber(value, 0);
}
function showChartMessage(message) {
  $('chart-state').textContent = message;
  $('chart-state').hidden = false;
}
function hideChartMessage() { $('chart-state').hidden = true; }

function initChart() {
  if (!window.LightweightCharts) {
    showChartMessage('Biblioteka wykresów nie została załadowana. Sprawdź połączenie z Internetem.');
    return false;
  }
  const L = LightweightCharts;
  chart = L.createChart($('chart'), {
    layout: { background: { type: 'solid', color: '#111927' }, textColor: '#8191a6', fontSize: 11 },
    grid: { vertLines: { color: '#1f2b3b' }, horzLines: { color: '#1f2b3b' } },
    rightPriceScale: { borderColor: '#304056', scaleMargins: { top: 0.12, bottom: 0.25 } },
    timeScale: { borderColor: '#304056', timeVisible: true, secondsVisible: false, rightOffset: 5 },
    crosshair: { mode: L.CrosshairMode.Normal },
    handleScroll: true,
    handleScale: true,
    localization: { locale: 'pl-PL' },
    autoSize: true,
    attributionLogo: true,
  });
  lineSeries = chart.addSeries(L.AreaSeries, {
    lineColor: '#8de2a6', topColor: 'rgba(94, 194, 127, 0.26)',
    bottomColor: 'rgba(94, 194, 127, 0.005)', lineWidth: 2, priceLineVisible: true,
  });
  candleSeries = chart.addSeries(L.CandlestickSeries, {
    upColor: '#84dca1', downColor: '#f28d91', borderVisible: false,
    wickUpColor: '#84dca1', wickDownColor: '#f28d91', visible: false,
  });
  volumeSeries = chart.addSeries(L.HistogramSeries, {
    priceFormat: { type: 'volume' }, priceScaleId: 'volume',
    priceLineVisible: false, lastValueVisible: false,
  });
  volumeSeries.priceScale().applyOptions({ scaleMargins: { top: 0.82, bottom: 0 } });
  chart.subscribeCrosshairMove((param) => {
    if (!param?.time) {
      $('hover-value').textContent = 'Najedź na wykres, aby zobaczyć szczegóły';
      return;
    }
    const point = param.seriesData.get(state.mode === 'candle' ? candleSeries : lineSeries);
    if (!point) return;
    const price = point.close ?? point.value;
    const day = typeof param.time === 'string'
      ? param.time
      : new Date(param.time * 1000).toLocaleString('pl-PL', { timeZone: 'UTC', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) + ' UTC';
    $('hover-value').textContent = `${day}  ·  ${formatNumber(price, 2)} ${state.data?.currency || ''}`;
  });
  return true;
}

async function getJSON(url, signal) {
  const response = await fetch(url, { signal, headers: { Accept: 'application/json' } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
  return body;
}

async function loadStock(symbol = state.symbol, force = false) {
  state.symbol = symbol.toUpperCase();
  const request = ++state.request;
  showChartMessage(`Pobieranie notowań ${state.symbol}…`);
  $('refresh-btn').disabled = true;
  try {
    const url = `/api/history?symbol=${encodeURIComponent(state.symbol)}&range=${encodeURIComponent(state.range)}${force ? `&refresh=${Date.now()}` : ''}`;
    const data = await getJSON(url);
    if (request !== state.request) return;
    state.data = data;
    renderStock();
    hideChartMessage();
  } catch (error) {
    if (request !== state.request) return;
    showChartMessage(`Nie udało się pobrać notowań: ${error.message}. Wybierz inną spółkę lub spróbuj później.`);
    $('stock-description').textContent = 'Brak dostępnych notowań';
  } finally {
    if (request === state.request) $('refresh-btn').disabled = false;
  }
}

function renderStock() {
  const data = state.data;
  $('stock-name').textContent = data.name || data.symbol;
  $('stock-symbol').textContent = data.symbol;
  $('asset-icon').textContent = data.symbol[0] || '?';
  $('stock-description').textContent = `${data.provider} · ${data.bars.length} obserwacji · ostatni punkt: ${formatBarTime(data.last_bar_time)}`;
  $('current-price').textContent = formatNumber(data.price, data.price < 1 ? 4 : 2);
  $('currency-label').textContent = data.currency || '';
  const sign = data.change > 0 ? '+' : '';
  $('price-change').textContent = `${sign}${formatNumber(data.change)} (${sign}${formatNumber(data.change_percent)}%)`;
  $('price-change').className = `change ${data.change > 0 ? 'positive' : data.change < 0 ? 'negative' : 'neutral'}`;
  const pricesHigh = data.bars.map((p) => p.high);
  const pricesLow = data.bars.map((p) => p.low);
  $('period-high').textContent = `${formatNumber(Math.max(...pricesHigh))} ${data.currency}`;
  $('period-low').textContent = `${formatNumber(Math.min(...pricesLow))} ${data.currency}`;
  $('period-volume').textContent = formatVolume(data.bars.reduce((sum, item) => sum + item.volume, 0));
  $('period-bars').textContent = formatNumber(data.bars.length, 0);
  $('provider').textContent = `Źródło: ${data.provider}`;
  $('stock-search').value = '';
  hideSuggestions();
  if (!chart && !initChart()) return;
  lineSeries.setData(data.bars.map((p) => ({ time: p.time, value: p.close })));
  candleSeries.setData(data.bars.map((p) => ({
    time: p.time, open: p.open, high: p.high, low: p.low, close: p.close,
  })));
  volumeSeries.setData(data.bars.map((p) => ({
    time: p.time, value: p.volume, color: p.close >= p.open ? '#335e4c' : '#673e4b',
  })));
  updateChartMode();
  chart.applyOptions({ timeScale: { timeVisible: !data.daily } });
  chart.timeScale().fitContent();
}
function formatBarTime(barTime) {
  if (typeof barTime === 'string') return barTime;
  return new Date(barTime * 1000).toLocaleString('pl-PL', {
    timeZone: 'UTC', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'
  }) + ' UTC';
}
function updateChartMode() {
  if (!chart) return;
  lineSeries.applyOptions({ visible: state.mode === 'line' });
  candleSeries.applyOptions({ visible: state.mode === 'candle' });
}
function updateButtons(selector, attr, value) {
  document.querySelectorAll(selector).forEach((btn) => {
    const selected = btn.dataset[attr] === value;
    btn.classList.toggle('active', selected);
    btn.setAttribute('aria-pressed', String(selected));
  });
}

function hideSuggestions() { $('suggestions').hidden = true; suggestions = []; chosen = -1; }
function renderSuggestions(items) {
  suggestions = items;
  chosen = -1;
  const list = $('suggestions');
  list.replaceChildren();
  items.forEach((item, index) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'suggestion';
    button.setAttribute('role', 'option');
    button.id = `suggestion-${index}`;
    const symbol = document.createElement('span'); symbol.className = 'sugg-symbol'; symbol.textContent = item.symbol;
    const name = document.createElement('span'); name.className = 'sugg-name'; name.textContent = item.name;
    const exch = document.createElement('span'); exch.className = 'sugg-exchange'; exch.textContent = item.exchange || '';
    button.append(symbol, name, exch);
    button.addEventListener('click', () => chooseStock(item.symbol));
    list.appendChild(button);
  });
  list.hidden = items.length === 0;
}
function chooseStock(symbol) {
  if (!symbol) return;
  hideSuggestions();
  loadStock(symbol);
}
function isTicker(text) { return /^[a-zA-Z0-9.^=\-]{1,20}$/.test(text); }
function searchInput() {
  const q = $('stock-search').value.trim();
  clearTimeout(searchTimer);
  if (searchController) searchController.abort();
  if (!q) return hideSuggestions();
  searchTimer = setTimeout(async () => {
    const controller = new AbortController(); searchController = controller;
    try {
      const data = await getJSON(`/api/search?q=${encodeURIComponent(q)}`, controller.signal);
      if (controller.signal.aborted || q !== $('stock-search').value.trim()) return;
      const results = data.results || [];
      if (isTicker(q) && !results.some((v) => v.symbol.toUpperCase() === q.toUpperCase())) {
        results.unshift({ symbol: q.toUpperCase(), name: 'Sprawdź symbol', exchange: '' });
      }
      renderSuggestions(results.slice(0, 10));
    } catch (error) {
      if (error.name === 'AbortError') return;
      if (isTicker(q)) renderSuggestions([{ symbol: q.toUpperCase(), name: 'Sprawdź symbol', exchange: '' }]);
      else hideSuggestions();
    }
  }, 260);
}

function boot() {
  $('year').textContent = String(new Date().getFullYear());
  $('today-label').textContent = new Date().toLocaleDateString('pl-PL', { day: 'numeric', month: 'short', year: 'numeric' });
  document.querySelectorAll('[data-range]').forEach((btn) => btn.addEventListener('click', () => {
    state.range = btn.dataset.range;
    updateButtons('[data-range]', 'range', state.range);
    loadStock();
  }));
  document.querySelectorAll('[data-chart]').forEach((btn) => btn.addEventListener('click', () => {
    state.mode = btn.dataset.chart;
    updateButtons('[data-chart]', 'chart', state.mode);
    updateChartMode();
  }));
  document.querySelectorAll('[data-symbol]').forEach((btn) => btn.addEventListener('click', () => chooseStock(btn.dataset.symbol)));
  $('refresh-btn').addEventListener('click', () => loadStock(state.symbol, true));
  $('stock-search').addEventListener('input', searchInput);
  $('stock-search').addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { hideSuggestions(); return; }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      if ($('suggestions').hidden || !suggestions.length) return;
      event.preventDefault();
      chosen = (chosen + (event.key === 'ArrowDown' ? 1 : -1) + suggestions.length) % suggestions.length;
      $('suggestions').querySelectorAll('.suggestion').forEach((button, index) => button.classList.toggle('selected', chosen === index));
      $('stock-search').setAttribute('aria-activedescendant', `suggestion-${chosen}`);
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      const input = $('stock-search').value.trim();
      if (chosen >= 0 && suggestions[chosen]) chooseStock(suggestions[chosen].symbol);
      else if (suggestions.length) chooseStock(suggestions[0].symbol);
      else if (isTicker(input)) chooseStock(input);
    }
  });
  document.addEventListener('click', (event) => {
    if (!$('search-box').contains(event.target)) hideSuggestions();
  });
  document.addEventListener('keydown', (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault(); $('stock-search').focus();
    }
  });
  if (!initChart()) return;
  loadStock('AAPL');
  // A small delay in quote updates is acceptable for this educational dashboard.
  setInterval(() => { if (!document.hidden) loadStock(); }, 120_000);
}

document.addEventListener('DOMContentLoaded', boot);
