// WebView APM JavaScript Agent
// 该脚本应在 atDocumentStart 注入

(function () {
    'use strict';

    // --- 配置 ---
    // 这个值会被 Native 代码动态替换为配置的 Handler 名称
    const MESSAGE_HANDLER_NAME = "{{MESSAGE_HANDLER_NAME_PLACEHOLDER}}"; // 例如 'apmHandler'
    const NATIVE_BRIDGE = window.webkit?.messageHandlers?.[MESSAGE_HANDLER_NAME];

    if (!NATIVE_BRIDGE) {
        console.error("WebViewAPM Agent: Native bridge not found for handler:", MESSAGE_HANDLER_NAME);
        return; // 无法与 Native 通信，停止执行
    }

    // --- 工具函数 ---
    function getTimestamp() {
        // 使用 performance.timeOrigin + performance.now() 提供更高精度的相对时间戳
        // Native 端可以结合设备当前时间还原为 Unix 时间戳
        // 或者直接使用 Date.now() / 1000 获取 Unix 时间戳（秒）
        return Date.now() / 1000;
    }

    function safeStringify(obj) {
        try {
            // 处理循环引用等问题
            const cache = new Set();
            return JSON.stringify(obj, (key, value) => {
                if (typeof value === 'object' && value !== null) {
                    if (cache.has(value)) {
                        // 移除循环引用
                        return '[Circular Reference]';
                    }
                    cache.add(value);
                }
                // 可以添加其他过滤逻辑，比如移除过大的字段
                return value;
            });
        } catch (e) {
            console.error("WebViewAPM Agent: Error stringifying object:", e);
            return JSON.stringify({ error: "Failed to stringify object" });
        }
    }

    // --- 通信函数 (Checklist Item 7) ---
    function sendToNative(recordType, data) {
        if (!NATIVE_BRIDGE) return; // 再次检查
        const record = {
            type: recordType, // 对应 Swift APMRecordType 的 rawValue
            data: data
        };
        try {
            // 发送给 Native
            NATIVE_BRIDGE.postMessage(record);
        } catch (e) {
            // 如果 postMessage 出错（例如数据过大或无法序列化），尝试发送简化错误信息
            console.error("WebViewAPM Agent: Failed to post message:", e);
            try {
                NATIVE_BRIDGE.postMessage({
                    type: 'jsError', // 上报为 JS 错误
                    data: {
                        message: 'WebViewAPM Agent: Failed to post original message. Type: ' + recordType,
                        stack: e.stack || '',
                        url: window.location.href,
                        timestamp: getTimestamp()
                    }
                });
            } catch (finalError) {
                console.error("WebViewAPM Agent: Failed to post fallback error message:", finalError);
            }
        }
    }

    // --- 页面加载性能监控 (Checklist Item 4 - Page Load) ---
    function capturePageLoadMetrics() {
        try {
            // 确保在 load 事件后执行，此时 timing 数据最完整
            if (document.readyState !== 'complete') {
                window.addEventListener('load', capturePageLoadMetrics, { once: true });
                return;
            }

            // 优先使用 PerformanceNavigationTiming (Level 2)
            const navigationEntries = performance.getEntriesByType?.('navigation');
            const navEntry = navigationEntries?.[0];

            let paintEntries = {};
            try {
                performance.getEntriesByType?.('paint')?.forEach(entry => {
                    paintEntries[entry.name] = entry.startTime; // FP 和 FCP
                });
            } catch (paintError) {
                console.warn("WebViewAPM Agent: Error getting Paint Timing:", paintError);
            }

            let data;
            const timestamp = getTimestamp(); // 记录发生时间

            if (navEntry) {
                data = {
                    timestamp: timestamp,
                    url: navEntry.name || window.location.href,
                    navigationStart: 0, // Level 2 时间是相对于 timeOrigin，所以 navigationStart 视为 0
                    domContentLoadedEventEnd: navEntry.domContentLoadedEventEnd,
                    loadEventEnd: navEntry.loadEventEnd,
                    firstPaint: paintEntries['first-paint'],
                    firstContentfulPaint: paintEntries['first-contentful-paint'],

                    // --- 新增详细时间点 (Level 2) ---
                    unloadEventStart: navEntry.unloadEventStart,
                    unloadEventEnd: navEntry.unloadEventEnd,
                    redirectStart: navEntry.redirectStart,
                    redirectEnd: navEntry.redirectEnd,
                    fetchStart: navEntry.fetchStart,
                    domainLookupStart: navEntry.domainLookupStart,
                    domainLookupEnd: navEntry.domainLookupEnd,
                    connectStart: navEntry.connectStart,
                    connectEnd: navEntry.connectEnd,
                    secureConnectionStart: navEntry.secureConnectionStart, // 可能为 0
                    requestStart: navEntry.requestStart,
                    responseStart: navEntry.responseStart,
                    responseEnd: navEntry.responseEnd,
                    domInteractive: navEntry.domInteractive,
                    domContentLoadedEventStart: navEntry.domContentLoadedEventStart,
                    domComplete: navEntry.domComplete,
                    loadEventStart: navEntry.loadEventStart,

                    // --- Level 2 Only 详细信息 ---
                    workerStart: navEntry.workerStart, // 可能为 0
                    transferSize: navEntry.transferSize,
                    encodedBodySize: navEntry.encodedBodySize,
                    decodedBodySize: navEntry.decodedBodySize
                };
                // 将 0 值转换成 null，因为 0 在 Level 2 中表示未发生或不适用
                for (const key in data) {
                    if (data[key] === 0 && key !== 'navigationStart') { // navigationStart 基准保持 0
                        data[key] = null;
                    }
                }
            } else if (performance.timing) {
                // Fallback 到 PerformanceTiming (Level 1)
                const timing = performance.timing;
                const navigationStart = timing.navigationStart; // Level 1 的基准时间戳
                // 辅助函数处理 Level 1 时间戳转换
                const getRelativeTime = (absoluteTime) => {
                    // 如果绝对时间为 0 (表示未发生) 或 navigationStart 无效，返回 null
                    if (!absoluteTime || !navigationStart) return null;
                    // 否则返回相对时间
                    return absoluteTime - navigationStart;
                };

                data = {
                    timestamp: timestamp,
                    url: window.location.href,
                    navigationStart: 0, // 统一基准为 0
                    domContentLoadedEventEnd: getRelativeTime(timing.domContentLoadedEventEnd),
                    loadEventEnd: getRelativeTime(timing.loadEventEnd),
                    firstPaint: paintEntries['first-paint'], // FP/FCP 仍可能来自 PaintTiming
                    firstContentfulPaint: paintEntries['first-contentful-paint'],

                    // --- 新增详细时间点 (Level 1 Fallback) ---
                    unloadEventStart: getRelativeTime(timing.unloadEventStart),
                    unloadEventEnd: getRelativeTime(timing.unloadEventEnd),
                    redirectStart: getRelativeTime(timing.redirectStart),
                    redirectEnd: getRelativeTime(timing.redirectEnd),
                    fetchStart: getRelativeTime(timing.fetchStart),
                    domainLookupStart: getRelativeTime(timing.domainLookupStart),
                    domainLookupEnd: getRelativeTime(timing.domainLookupEnd),
                    connectStart: getRelativeTime(timing.connectStart),
                    connectEnd: getRelativeTime(timing.connectEnd),
                    // secureConnectionStart 在 Level 1 中不存在
                    secureConnectionStart: null,
                    requestStart: getRelativeTime(timing.requestStart),
                    responseStart: getRelativeTime(timing.responseStart),
                    responseEnd: getRelativeTime(timing.responseEnd),
                    domInteractive: getRelativeTime(timing.domInteractive),
                    domContentLoadedEventStart: getRelativeTime(timing.domContentLoadedEventStart),
                    domComplete: getRelativeTime(timing.domComplete),
                    loadEventStart: getRelativeTime(timing.loadEventStart),

                    // --- Level 2 Only 字段在 Level 1 中不存在 ---
                    workerStart: null,
                    transferSize: null,
                    encodedBodySize: null,
                    decodedBodySize: null
                };
            } else {
                console.warn("WebViewAPM Agent: Navigation Timing API not fully supported.");
                return; // 无法获取数据
            }

            // 过滤掉结果为 Infinity 的值 (可能在某些异常情况下出现)
            for (const key in data) {
                if (data[key] === Infinity || data[key] === -Infinity) {
                    data[key] = null;
                }
            }

            sendToNative('pageLoad', data);
        } catch (e) {
            console.error("WebViewAPM Agent: Error capturing page load metrics:", e);
            // 尝试上报这个错误
            sendToNative('jsError', { timestamp: getTimestamp(), message: 'Error capturing page load metrics: ' + e.message, stack: e.stack });
        }
    }

    // --- 资源加载性能监控 (Checklist Item 4 - Resource Load) ---
    function captureResourceLoadMetrics() {
        try {
            if (typeof performance.getEntriesByType !== 'function') {
                console.warn("WebViewAPM Agent: Resource Timing API not supported.");
                return;
            }

            const resources = performance.getEntriesByType('resource');
            const navigationStart = performance.timing ? performance.timing.navigationStart : 0; // 基准时间

            resources.forEach(resource => {
                // 过滤掉自身脚本和可能的 beacon 请求（如果使用 Beacon API 上报）
                if (resource.name.includes('JavaScriptAgent.js') || resource.initiatorType === 'beacon') {
                    return;
                }
                const data = {
                    timestamp: getTimestamp(), // 记录发生时间
                    url: resource.name,
                    initiatorType: resource.initiatorType,
                    startTime: resource.startTime, // 相对于 navigationStart
                    duration: resource.duration,
                    transferSize: resource.transferSize,
                    decodedBodySize: resource.decodedBodySize
                };
                sendToNative('resourceLoad', data);
            });

            // 清空已上报资源，避免重复（如果需要周期性检查）
            // performance.clearResourceTimings();
        } catch (e) {
            console.error("WebViewAPM Agent: Error capturing resource load metrics:", e);
            sendToNative('jsError', { timestamp: getTimestamp(), message: 'Error capturing resource load metrics: ' + e.message, stack: e.stack });
        }
    }

    // --- JS 错误监控 (Checklist Item 5) ---
    function captureJSErrors() {
        try {
            const originalOnError = window.onerror;
            window.onerror = function (message, source, lineno, colno, error) {
                try { // 内层 try-catch 保护日志逻辑本身
                    const data = {
                        timestamp: getTimestamp(),
                        message: message,
                        url: source,
                        line: lineno,
                        column: colno,
                        stack: error ? error.stack : null,
                        errorType: error ? error.name : null
                    };
                    sendToNative('jsError', data);
                } catch (logError) {
                    console.error("WebViewAPM Agent: Error logging in window.onerror:", logError);
                }

                // 调用原始的 onerror (如果存在)
                if (originalOnError) {
                    // 用 try-catch 保护原始处理器的调用
                    try { return originalOnError.apply(this, arguments); } catch (e) { /* ignore */ }
                }
                // 返回 false 以允许默认的浏览器错误处理继续
                return false;
            };

            window.addEventListener('unhandledrejection', function (event) {
                try { // 内层 try-catch 保护日志逻辑本身
                    const reason = event.reason;
                    let data = {
                        timestamp: getTimestamp(),
                        message: 'Unhandled Promise Rejection',
                        stack: null,
                        errorType: 'PromiseRejection'
                    };
                    if (reason instanceof Error) {
                        data.message = reason.message;
                        data.stack = reason.stack;
                        data.errorType = reason.name;
                    } else {
                        // 如果 reason 不是 Error 对象，尝试转换为字符串
                        try {
                            data.message = safeStringify(reason);
                        } catch (e) {
                            data.message = 'Unhandled Promise Rejection with non-serializable reason';
                        }
                    }
                    sendToNative('jsError', data);
                } catch (logError) {
                    console.error("WebViewAPM Agent: Error logging in unhandledrejection:", logError);
                }
            });
        } catch (e) {
            console.error("WebViewAPM Agent: Error setting up JS error capture:", e);
        }
    }

    // --- API 调用监控 (Checklist Item 6) ---
    function captureApiCalls() {
        try {
            // 监控 XMLHttpRequest
            const originalXhrOpen = XMLHttpRequest.prototype.open;
            const originalXhrSend = XMLHttpRequest.prototype.send;

            XMLHttpRequest.prototype.open = function (method, url) {
                try {
                    // 存储请求信息到 XHR 实例上，供 send 和事件监听器使用
                    this._apm_method = method;
                    this._apm_url = url;
                } catch (e) {
                    console.error("WebViewAPM Agent: Error in XHR open patch:", e);
                }
                return originalXhrOpen.apply(this, arguments);
            };

            XMLHttpRequest.prototype.send = function (body) {
                try {
                    const xhr = this;
                    const startTime = performance.now(); // 高精度起始时间
                    let requestSize = null;
                    if (body) {
                        if (typeof body === 'string') {
                            requestSize = body.length;
                        } else if (body instanceof Blob) {
                            requestSize = body.size;
                        } else if (body instanceof ArrayBuffer) {
                            requestSize = body.byteLength;
                        }
                        // FormData 较难精确计算
                    }

                    const handleFinish = () => {
                        try { // 内层 try-catch
                            // 移除监听器，避免重复调用
                            xhr.removeEventListener('load', handleLoad);
                            xhr.removeEventListener('error', handleError);
                            xhr.removeEventListener('abort', handleAbort);
                            xhr.removeEventListener('timeout', handleTimeout);

                            const duration = performance.now() - startTime;
                            let success = xhr.status >= 200 && xhr.status < 300;
                            let responseSize = null;
                            try {
                                responseSize = xhr.response ? (xhr.response.length || xhr.response.byteLength || xhr.response.size) : null;
                                // 对于 responseText, 可以 xhr.responseText.length
                                if (xhr.getResponseHeader('Content-Length')) {
                                    responseSize = parseInt(xhr.getResponseHeader('Content-Length'), 10);
                                }
                            } catch (e) { } // 忽略获取 response 大小的错误

                            const data = {
                                timestamp: getTimestamp(),
                                url: xhr._apm_url || '',
                                method: xhr._apm_method || 'GET',
                                startTime: startTime, // 相对时间戳
                                duration: duration,
                                statusCode: xhr.status === 0 ? null : xhr.status, // status 为 0 通常是网络错误或跨域问题
                                requestSize: requestSize,
                                responseSize: responseSize,
                                success: success,
                                errorMessage: success ? null : (xhr.status === 0 ? 'Network Error or CORS' : xhr.statusText)
                            };
                            sendToNative('apiCall', data);
                        } catch (logError) {
                            console.error("WebViewAPM Agent: Error logging in XHR handleFinish:", logError);
                        }
                    };

                    // 使用具名函数方便移除
                    const handleLoad = () => handleFinish();
                    const handleError = () => handleFinish();
                    const handleAbort = () => handleFinish();
                    const handleTimeout = () => handleFinish();


                    // 添加事件监听器
                    xhr.addEventListener('load', handleLoad);
                    xhr.addEventListener('error', handleError);
                    xhr.addEventListener('abort', handleAbort);
                    xhr.addEventListener('timeout', handleTimeout);
                } catch (e) {
                    console.error("WebViewAPM Agent: Error in XHR send patch setup:", e);
                }

                return originalXhrSend.apply(this, arguments);
            };

            // 监控 Fetch API
            if (window.fetch) {
                const originalFetch = window.fetch;
                window.fetch = function (input, init) {
                    let startTime, url, method, requestSize; // 声明在 try 外部
                    try {
                        startTime = performance.now();
                        url = (input instanceof Request) ? input.url : input;
                        method = (input instanceof Request) ? input.method : (init?.method || 'GET');
                        requestSize = null;
                        const body = (input instanceof Request) ? input.body : init?.body;
                        if (body) {
                            if (typeof body === 'string') {
                                requestSize = body.length;
                            } else if (body instanceof Blob) {
                                requestSize = body.size;
                            } else if (body instanceof ArrayBuffer) {
                                requestSize = body.byteLength;
                            }
                        }
                    } catch (e) {
                        console.error("WebViewAPM Agent: Error in fetch patch setup:", e);
                        // 如果 setup 失败，直接调用原始 fetch 并返回
                        return originalFetch.apply(this, arguments);
                    }

                    return originalFetch.apply(this, arguments)
                        .then(response => {
                            try { // 内层 try-catch
                                const duration = performance.now() - startTime;
                                let responseSize = null;
                                const contentLength = response.headers.get('Content-Length');
                                if (contentLength) {
                                    responseSize = parseInt(contentLength, 10);
                                } else {
                                    // 如果没有 Content-Length，尝试克隆读取，但这可能影响性能且不总可行
                                    // response.clone().blob().then(blob => { responseSize = blob.size; });
                                }

                                const data = {
                                    timestamp: getTimestamp(),
                                    url: url,
                                    method: method,
                                    startTime: startTime,
                                    duration: duration,
                                    statusCode: response.status,
                                    requestSize: requestSize,
                                    responseSize: responseSize,
                                    success: response.ok,
                                    errorMessage: response.ok ? null : response.statusText
                                };
                                sendToNative('apiCall', data);
                            } catch (logError) {
                                console.error("WebViewAPM Agent: Error logging in fetch then block:", logError);
                            }
                            return response; // 返回原始 response
                        })
                        .catch(error => {
                            try { // 内层 try-catch
                                const duration = performance.now() - startTime;
                                const data = {
                                    timestamp: getTimestamp(),
                                    url: url,
                                    method: method,
                                    startTime: startTime,
                                    duration: duration,
                                    statusCode: null,
                                    requestSize: requestSize,
                                    responseSize: null,
                                    success: false,
                                    errorMessage: error.message || 'Fetch Failed'
                                };
                                sendToNative('apiCall', data);
                            } catch (logError) {
                                console.error("WebViewAPM Agent: Error logging in fetch catch block:", logError);
                            }
                            throw error; // 重新抛出错误，不破坏 Promise 链
                        });
                };
            }
        } catch (e) {
            console.error("WebViewAPM Agent: Error setting up API call capture:", e);
        }
    }

    // --- SPA (Single Page Application) Navigation Monitoring Placeholder (Checklist Item 5 - SPA Placeholder) ---
    function captureSPANavigation() {
        // TODO: Implement SPA navigation tracking.
        // This typically involves listening to 'popstate' and 'hashchange' events.
        // You might also need to wrap 'history.pushState' and 'history.replaceState'.
        // When a navigation occurs, you might want to:
        // 1. Send a 'pageView' or 'navigation' event similar to pageLoad.
        // 2. Reset or re-evaluate resource timings if needed for the new view.
        // Example listeners (add error handling):
        /*
        window.addEventListener('popstate', function(event) {
            console.log('APM SPA: popstate detected', window.location.href, event.state);
            sendToNative('spaNavigation', { timestamp: getTimestamp(), url: window.location.href });
        });
        window.addEventListener('hashchange', function(event) {
            console.log('APM SPA: hashchange detected', window.location.href);
            sendToNative('spaNavigation', { timestamp: getTimestamp(), url: window.location.href });
        });
        const originalPushState = history.pushState;
        history.pushState = function() {
            originalPushState.apply(this, arguments);
            console.log('APM SPA: pushState detected', window.location.href);
            sendToNative('spaNavigation', { timestamp: getTimestamp(), url: window.location.href });
        };
        */
    }

    // --- 初始化执行 ---
    function initAgent() {
        try {
            console.log("WebViewAPM Agent Initializing...");
            captureJSErrors();
            captureApiCalls();
            captureSPANavigation();

            // 页面加载和资源数据需要在文档加载的不同阶段捕获
            // 使用 setTimeout 稍微延迟执行，确保基础环境设置完毕
            // load 事件后捕获 PageLoad 和 Resource
            window.addEventListener('load', () => {
                setTimeout(capturePageLoadMetrics, 0);
                setTimeout(captureResourceLoadMetrics, 50); // 稍微延迟，等待可能的后续资源加载
            }, { once: true });

            console.log("WebViewAPM Agent Initialized.");
        } catch (e) {
            console.error("WebViewAPM Agent: Error during initialization:", e);
        }
    }

    // --- 启动 ---
    // 确保 DOM Ready 后再执行某些初始化，但错误和 API 监控需要尽早开始
    if (document.readyState === 'loading') {
        // 尽早开始错误和 API 捕获
        captureJSErrors();
        captureApiCalls();
        document.addEventListener('DOMContentLoaded', initAgent, { once: true });
    } else {
        // 如果已经 ready 或 complete
        initAgent();
    }

})(); 