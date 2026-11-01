// SPDX-License-Identifier: GPL-2.0-or-later
// The data broadcast browser, run in a WKWebView by the DataBroadcasting plugin. web-bml does the
// real work; this file connects it to the plugin. Based on browser/src/TVTDataBroadcastingWV2.ts of
// TVTDataBroadcastingWV2 by otya (MIT License, see LICENSE.TVTDataBroadcastingWV2).
import type { ComponentPMT, ResponseMessage } from "web-bml/protocol";
import { BMLBrowser, BMLBrowserFontFace, EPG, Indicator, IP, InputApplication, InputCharacterType } from "web-bml";
import { decodeTS } from "web-bml/ts";

type FromPage = {
    type: "video",
    x: number,
    y: number,
    width: number,
    height: number,
    invisible: boolean,
    fullScreen: boolean,
} | {
    type: "documentLoaded",
} | {
    type: "tune",
    originalNetworkId: number,
    transportStreamId: number,
    serviceId: number,
} | {
    type: "usedKeyList",
    usedKeyList: string[],
} | {
    type: "input",
    characterType: InputCharacterType,
    allowedCharacters?: string,
    maxLength: number,
    value: string,
    inputMode: "text" | "password",
    multiline: boolean,
} | {
    type: "cancelInput",
} | {
    type: "changeAudioStream",
    componentId: number,
    index: number,
    channelId?: number,
} | {
    type: "changeMainAudioStream",
    index: number,
    channelId?: number,
} | {
    type: "startBrowser",
    uri: string,
} | {
    type: "error",
    title: string,
    message: string,
};

type HTTPRequest = {
    method: "GET" | "POST",
    uri: string,
    body?: string,
};

type HTTPReply = {
    statusCode: number,
    headers: Record<string, string>,
    body: string,
};

declare global {
    interface Window {
        webkit: {
            messageHandlers: {
                bonbori: { postMessage(message: FromPage): void },
                bonboriHTTP: { postMessage(request: HTTPRequest): Promise<HTTPReply | null> },
            },
        };
        // What the plugin calls.
        bonbori: {
            stream(base64: string): void,
            key(keyCode: number): void,
            volume(value: number): void,
            enableNetwork(enable: boolean): void,
            changeInput(value: string): void,
            cancelInput(): void,
            mainAudioStreamChanged(index: number, channelId?: number): void,
            nvramRead(filename: string, structure: string): any[] | null,
            nvramWrite(filename: string, structure: string, data: any[]): void,
            nvramDelete(): void,
        };
    }
}

function post(message: FromPage): void {
    window.webkit.messageHandlers.bonbori.postMessage(message);
}

function fromBase64(input: string): Uint8Array<ArrayBuffer> {
    return Uint8Array.from(window.atob(input), c => c.charCodeAt(0));
}

function toBase64(input: Uint8Array): string {
    let binary = "";
    for (const byte of input) {
        binary += String.fromCharCode(byte);
    }
    return window.btoa(binary);
}

const params = new URLSearchParams(location.search);
const serviceId = Number(params.get("serviceId")) || undefined;

// BML文書と動画が入る要素
const browserElement = document.getElementById("data-broadcasting-browser")!;
// 動画が入っている要素
const videoContainer = browserElement.querySelector(".arib-video-container") as HTMLElement;
// BML文書が入る要素
const contentElement = browserElement.querySelector(".data-broadcasting-browser-content") as HTMLElement;

class StatusIndicator implements Indicator {
    private receiving = false;
    private networkingPost = false;
    constructor(private readonly receivingElement: HTMLElement, private readonly networkingElement: HTMLElement) {
    }
    private update() {
        this.receivingElement.style.display = this.receiving ? "" : "none";
        this.networkingElement.style.display = this.networkingPost ? "" : "none";
    }
    public setUrl(_name: string, _loading: boolean): void {
    }
    public setReceivingStatus(receiving: boolean): void {
        this.receiving = receiving;
        this.update();
    }
    public setNetworkingGetStatus(_get: boolean): void {
    }
    public setNetworkingPostStatus(post: boolean): void {
        this.networkingPost = post;
        this.update();
    }
    public setEventName(_eventName: string | null): void {
    }
}

const indicator = new StatusIndicator(
    browserElement.querySelector(".remote-control-receiving-status")!,
    browserElement.querySelector(".remote-control-networking-status")!,
);
const statusContainer = document.querySelector(".remote-control-status-container") as HTMLElement;
statusContainer.style.visibility = "hidden";

// BML用フォント。ARIBの半角に合わせた幅を持つフォントを同梱し、読めなければシステムの丸ゴシックを使う
const roundGothic: BMLBrowserFontFace = { source: "url('KosugiMaru-Regular.woff2'), local('Hiragino Maru Gothic ProN')" };
const boldRoundGothic: BMLBrowserFontFace = { source: "url('KosugiMaru-Bold.woff2'), local('Hiragino Maru Gothic ProN')" };
const squareGothic: BMLBrowserFontFace = { source: "url('Kosugi-Regular.woff2'), local('Hiragino Sans')" };

const epg: EPG = {
    tune(originalNetworkId, transportStreamId, serviceId) {
        post({ type: "tune", originalNetworkId, transportStreamId, serviceId });
        return true;
    },
};

let networkEnabled = false;
// 放送時刻から離れたストリーム (録画の再生など) では通信しない
let isRecord = false;

function canUseNetwork(): boolean {
    return networkEnabled && !isRecord;
}

const ip: IP = {
    getConnectionType() {
        return 403;
    },
    isIPConnected() {
        return canUseNetwork() ? 1 : 0;
    },
    async transmitTextDataOverIP(uri, body) {
        const failed = { resultCode: NaN, statusCode: "", response: new Uint8Array() };
        if (!canUseNetwork()) {
            return failed;
        }
        const reply = await window.webkit.messageHandlers.bonboriHTTP.postMessage({ method: "POST", uri, body: toBase64(body) });
        if (reply == null) {
            return failed;
        }
        return { resultCode: 1, statusCode: reply.statusCode.toString(), response: fromBase64(reply.body) };
    },
    async get(uri) {
        if (!canUseNetwork()) {
            return {};
        }
        const reply = await window.webkit.messageHandlers.bonboriHTTP.postMessage({ method: "GET", uri });
        if (reply == null) {
            return {};
        }
        return { statusCode: reply.statusCode, headers: new Headers(reply.headers), response: fromBase64(reply.body) };
    },
};

const audioContext = new AudioContext();
const gainNode = audioContext.createGain();
gainNode.connect(audioContext.destination);

let changeCallback: ((value: string) => void) | undefined;

const inputApplication: InputApplication = {
    launch(opts) {
        if (changeCallback != null) {
            this.cancel("other");
        }
        post({
            type: "input",
            characterType: opts.characterType,
            maxLength: opts.maxLength,
            value: opts.value,
            allowedCharacters: opts.allowedCharacters,
            inputMode: opts.inputMode,
            multiline: opts.multiline,
        });
        changeCallback = opts.callback;
    },
    cancel(_reason) {
        if (changeCallback != null) {
            changeCallback = undefined;
            post({ type: "cancelInput" });
        }
    },
};

function X_DPA_startResidentApp(appName: string, _showAV: number, _returnURI: string, Ex_info: string[]): number {
    if (appName !== "ComBrowser") {
        return NaN;
    }
    const uri = Ex_info[0];
    const mode = Ex_info[1];
    if (!uri.startsWith("http://") && !uri.startsWith("https://")) {
        return NaN;
    }
    if (mode === "0") {
        // 0: 本規定に準じたコンテンツを表示可能なブラウザ
        // 非リンクコンテンツへと遷移 (TR-B14 第三分冊 図8-9)
        return NaN;
    }
    // 1: 通信事業者仕様ブラウザ
    // 2: HTMLブラウザ
    post({ type: "startBrowser", uri });
    // データ放送ブラウザは，当該拡張関数を実行後，引き続きスクリプトの実行を継続することが望ましい
    // TR-B14 第三分冊 7.10.8
    return 1;
}

let audioESList: ComponentPMT[] = [];

const bmlBrowser = new BMLBrowser({
    containerElement: contentElement,
    mediaElement: videoContainer,
    indicator,
    fonts: { roundGothic, boldRoundGothic, squareGothic },
    epg,
    videoPlaneModeEnabled: true,
    audioNodeProvider: {
        getAudioDestinationNode() {
            return gainNode;
        },
    },
    ip,
    inputApplication,
    greg: {
        getReg(index) {
            return window.sessionStorage.getItem(`Greg[${index}]`) ?? "";
        },
        setReg(index, value) {
            window.sessionStorage.setItem(`Greg[${index}]`, value);
        },
    },
    setMainAudioStreamCallback(componentId, channelId) {
        const index = audioESList.findIndex(x => x.componentId === componentId);
        if (index < 0) {
            return false;
        }
        post({ type: "changeMainAudioStream", index, channelId });
        return true;
    },
    X_DPA_startResidentApp,
    showErrorMessage(title, message) {
        post({ type: "error", title, message });
    },
});

function isFullScreenVideo(): boolean {
    return videoContainer.clientWidth === browserElement.clientWidth && videoContainer.clientHeight === browserElement.clientHeight;
}

function reportVideo() {
    const { left, top, right, bottom } = videoContainer.getBoundingClientRect();
    const windowWidth = document.documentElement.clientWidth;
    const windowHeight = document.documentElement.clientHeight;
    post({
        type: "video",
        x: left / windowWidth,
        y: top / windowHeight,
        width: (right - left) / windowWidth,
        height: (bottom - top) / windowHeight,
        invisible: bmlBrowser.content.invisible ?? true,
        fullScreen: isFullScreenVideo(),
    });
}

// trueであればデータ放送の上に動画を表示させる非表示状態
bmlBrowser.addEventListener("invisible", (evt) => {
    contentElement.style.clipPath = evt.detail ? "inset(0px)" : "";
    reportVideo();
});

bmlBrowser.addEventListener("load", (evt) => {
    const width = evt.detail.resolution.width + "px";
    const aspectNum = evt.detail.displayAspectRatio.numerator;
    const aspectDen = evt.detail.displayAspectRatio.denominator;
    const scaleY = (evt.detail.resolution.width / evt.detail.resolution.height) / (aspectNum / aspectDen);
    const transform = `scaleY(${scaleY})`;
    const height = (evt.detail.resolution.height * scaleY) + "px";
    if (browserElement.style.width !== width || browserElement.style.height !== height || contentElement.style.transform !== transform) {
        browserElement.style.width = width;
        browserElement.style.height = height;
        contentElement.style.transform = transform;
        onResized();
    }
    post({ type: "documentLoaded" });
});

bmlBrowser.addEventListener("videochanged", reportVideo);

bmlBrowser.addEventListener("usedkeylistchanged", (evt) => {
    post({ type: "usedKeyList", usedKeyList: [...evt.detail.usedKeyList.values()] });
});

bmlBrowser.addEventListener("audiostreamchanged", (evt) => {
    const { componentId, channelId } = evt.detail;
    post({ type: "changeAudioStream", componentId, index: audioESList.findIndex(x => x.componentId === componentId), channelId });
});

// LibISDB/Filters/AnalyzerFilter.cppを参照
const audioStreamType = new Set([0x03, 0x04, 0x0f, 0x11, 0x81, 0x82, 0x83, 0x87]);

function onMessage(msg: ResponseMessage) {
    if (msg.type === "pmt") {
        audioESList = msg.components.filter(x => audioStreamType.has(x.streamType)).sort((a, b) => a.componentId - b.componentId);
    } else if (msg.type === "currentTime") {
        isRecord = new Date().getTime() - msg.timeUnixMillis >= 5 * 60 * 1000;
    }
    bmlBrowser.emitMessage(msg);
}

const tsStream = decodeTS({ sendCallback: onMessage, serviceId });

// 1分間無操作であればデータ取得中の表示を消す
const statusTimeoutMillis = 60 * 1000;
let statusTimeout = Number.MAX_VALUE;

window.bonbori = {
    stream(base64) {
        if (performance.now() >= statusTimeout) {
            statusContainer.style.visibility = "hidden";
            statusTimeout = Number.MAX_VALUE;
        }
        tsStream.push(fromBase64(base64));
    },
    key(keyCode) {
        statusContainer.style.visibility = "visible";
        bmlBrowser.content.processKeyDown(keyCode as Parameters<typeof bmlBrowser.content.processKeyDown>[0]);
        bmlBrowser.content.processKeyUp(keyCode as Parameters<typeof bmlBrowser.content.processKeyUp>[0]);
        statusTimeout = performance.now() + statusTimeoutMillis;
    },
    volume(value) {
        gainNode.gain.value = value;
    },
    enableNetwork(enable) {
        networkEnabled = enable;
    },
    changeInput(value) {
        changeCallback?.(value);
        changeCallback = undefined;
    },
    cancelInput() {
        changeCallback = undefined;
    },
    mainAudioStreamChanged(index, channelId) {
        const es = audioESList[index];
        if (es != null) {
            bmlBrowser.setMainAudioStream(es.componentId, channelId);
        }
    },
    nvramRead(filename, structure) {
        return bmlBrowser.nvram.readPersistentArray(filename, structure);
    },
    nvramWrite(filename, structure, data) {
        bmlBrowser.nvram.writePersistentArray(filename, structure, data, undefined, true);
    },
    nvramDelete() {
        const keys: string[] = [];
        for (let i = 0; i < window.localStorage.length; i++) {
            const key = window.localStorage.key(i);
            if (key != null && key.startsWith("nvram_")) {
                keys.push(key);
            }
        }
        for (const key of keys) {
            window.localStorage.removeItem(key);
        }
    },
};

function onResized() {
    const windowWidth = document.documentElement.clientWidth;
    const windowHeight = document.documentElement.clientHeight;
    const contentWidth = browserElement.clientWidth;
    const contentHeight = browserElement.clientHeight;
    const s = Math.min(windowWidth / contentWidth, windowHeight / contentHeight);
    document.body.style.transform = `translate(${(windowWidth - contentWidth * s) / 2}px, ${(windowHeight - contentHeight * s) / 2}px) scale(${s})`;
    document.body.style.transformOrigin = "0px 0px";
    reportVideo();
}

window.addEventListener("resize", onResized);

onResized();
