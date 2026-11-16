/**
 * CarPlay JS 桥（Phase 1）
 *
 * 职责：
 *  - 车机连上 / 请求数据 -> 把歌单、曲目推给原生 CarPlayBridge
 *  - 车机点歌 -> 调 TrackPlayer 播放对应曲目（复用现有取链/会员歌修复）
 *  - 车机控制（播放/暂停/上一首/下一首）-> TrackPlayer
 *  - 播放状态变化 -> 推送 NowPlaying 给车机
 *
 * 通过 NativeModules.CarPlayBridge + NativeEventEmitter 双向通信。
 * iOS 无 CarPlay 模块时（安卓）所有调用静默降级为 no-op。
 */
import { NativeEventEmitter, NativeModules, Platform } from "react-native";

import MusicSheet from "@/core/musicSheet";
import TrackPlayer from "@/core/trackPlayer";
import { errorLog, trace } from "@/utils/log";
import { getDefaultStore } from "jotai";

const NativeBridge = NativeModules.CarPlayBridge;

/** 是否具备原生 CarPlay 桥 */
export const isCarPlayAvailable = Platform.OS === "ios" && !!NativeBridge;

let emitter: NativeEventEmitter | null = null;
let started = false;

function getEmitter(): NativeEventEmitter | null {
    if (!isCarPlayAvailable) {
        return null;
    }
    if (!emitter) {
        emitter = new NativeEventEmitter(NativeBridge);
    }
    return emitter;
}

/** 推送全部歌单 */
function pushSheets() {
    if (!NativeBridge?.setSheets) {
        return;
    }
    try {
        const sheets = MusicSheet.getAllSheetsForCarPlay();
        NativeBridge.setSheets(sheets);
        trace(`[CarPlay] push ${sheets.length} sheets`);
    } catch (e) {
        errorLog("[CarPlay] pushSheets", e);
    }
}

/** 推送某歌单曲目 */
function pushTracks(sheetId: string) {
    if (!NativeBridge?.setTracks || !sheetId) {
        return;
    }
    try {
        const tracks = MusicSheet.getTracksForCarPlay(sheetId);
        NativeBridge.setTracks(tracks, sheetId);
        trace(`[CarPlay] push ${tracks.length} tracks for ${sheetId}`);
    } catch (e) {
        errorLog("[CarPlay] pushTracks", e);
    }
}

/** 点歌：用 playWithReplacePlayList 播放整张歌单，从选中曲目开始 */
async function playTrack(trackId: string, sheetId: string) {
    try {
        const musicItem = MusicSheet.findMusicItemForCarPlay(sheetId, trackId);
        if (!musicItem) {
            errorLog("[CarPlay] track not found", { trackId, sheetId });
            return;
        }
        const list = MusicSheet.getSortedMusicListBySheetId(sheetId)?.musicList ?? [];
        if (!list.length) {
            return;
        }
        await TrackPlayer.playWithReplacePlayList(musicItem, [...list]);
        pushNowPlaying(musicItem);
    } catch (e) {
        errorLog("[CarPlay] playTrack", e);
    }
}

/** 推送正在播放 */
function pushNowPlaying(musicItem?: any) {
    if (!NativeBridge?.setNowPlaying) {
        return;
    }
    try {
        const title = musicItem?.title ?? "";
        const artist = musicItem?.artist ?? "";
        NativeBridge.setNowPlaying(title, artist);
    } catch (e) {
        errorLog("[CarPlay] pushNowPlaying", e);
    }
}

/** 车机控制指令 */
async function handleControl(action: string) {
    try {
        switch (action) {
            case "requestSheets":
                pushSheets();
                break;
            case "play":
                await TrackPlayer.play();
                break;
            case "pause":
                await TrackPlayer.pause();
                break;
            case "next":
                await TrackPlayer.skipToNext();
                break;
            case "prev":
                await TrackPlayer.skipToPrevious();
                break;
            default:
                break;
        }
    } catch (e) {
        errorLog("[CarPlay] handleControl", e);
    }
}

/* ============ 11142655：JS -> 原生 新通道 ============ */

/**
 * 11142657：推送歌词给原生（车机播放页滚动显示）。
 *
 * 歌词来源：lyricManager 的 lyricStateAtom
 *   结构：{ loading, lyrics: [{time, lrc, translation?, index}], hasTranslation }
 *
 * 原生需要的是 [{time, lrc, translation}]，这里做字段裁剪。
 */
function pushLyric() {
    if (!NativeBridge?.setLyric) {
        return;
    }
    try {
        /*
         * 动态 import 避免循环依赖：
         * lyricManager 依赖 trackPlayer，而本文件也被 bootstrap 引用。
         */
        const lyricModule = require("@/core/lyricManager");
        const mgr = lyricModule.default ?? lyricModule;
        const state = mgr?.lyricState;

        if (!state || !Array.isArray(state.lyrics)) {
            trace("[CarPlay] pushLyric: no lyric state");
            return;
        }

        if (state.loading) {
            trace("[CarPlay] pushLyric: still loading");
            return;
        }

        const lines = state.lyrics
            .filter((x: any) => typeof x?.time === "number" && typeof x?.lrc === "string")
            .map((x: any) => ({
                time: x.time,
                lrc: x.lrc,
                translation: x.translation ?? "",
            }));

        NativeBridge.setLyric(lines);
        trace(`[CarPlay] pushed ${lines.length} lyric lines`);
    } catch (e) {
        errorLog("[CarPlay] pushLyric", e);
    }
}

/**
 * 处理车机的联网搜索请求。
 *
 * 注意（构建 A 阶段）：
 *   这里先只打日志 + 回传空数组，用来验证「原生 -> JS -> 原生」通路是否打通。
 *   下一轮构建 B 再接真实插件搜索。
 */
async function handleSearch(query: string) {
    trace(`[CarPlay] search request: "${query}"`);
    try {
        /*
         * TODO(构建B)：接插件搜索
         *   const results = await searchByPlugins(query);
         * 现在先返回空，验证桥路。
         */
        const results: any[] = [];

        NativeBridge?.setSearchResults?.(results, query);
        trace(`[CarPlay] search reply: ${results.length} results`);
    } catch (e) {
        errorLog("[CarPlay] handleSearch", e);
    }
}

/**
 * 推送播放状态给原生（实时更新用）。
 *
 * 注意（构建 A 阶段）：
 *   只是把当前 TrackPlayer 状态快照发过去，验证通路。
 *   下一轮再加定时器做进度条实时刷新。
 */
async function pushNowPlayingState() {
    if (!NativeBridge?.setNowPlayingState) {
        return;
    }
    try {
        /*
         * 状态获取方式（已核对 trackPlayer 实现）：
         *   currentMusic / repeatMode / quality  -> 同步 getter
         *   progress                             -> getProgress() 异步
         *   isPlaying                            -> getPlaybackState() 异步
         */
        const music = TrackPlayer.currentMusic;

        let progress = 0;
        let duration = music?.duration ?? 0;
        try {
            const p = await TrackPlayer.getProgress();
            progress = p?.position ?? 0;
            duration = p?.duration ?? duration;
        } catch (e) {
            /* 没在播放时会抛，忽略 */
        }

        let isPlaying = 0;
        try {
            const st = await TrackPlayer.getPlaybackState();
            /* react-native-track-player 的 State.Playing = 3 */
            isPlaying = st?.state === 3 ? 1 : 0;
        } catch (e) {
            /* 忽略 */
        }

        NativeBridge.setNowPlayingState({
            title: music?.title ?? "",
            artist: music?.artist ?? "",
            album: music?.album ?? "",
            artwork: music?.artwork ?? "",
            progress,
            duration,
            isPlaying,
            repeatMode: TrackPlayer.repeatMode ?? "loop",
            quality: TrackPlayer.quality ?? "standard",
            rate: 1.0,
            isFavorite: 0,
        });
        trace(`[CarPlay] pushed state: ${music?.title ?? "(none)"} playing=${isPlaying} progress=${progress}`);
    } catch (e) {
        errorLog("[CarPlay] pushNowPlayingState", e);
    }
}


/**
 * 启动时调用一次（bootstrap 里），注册所有监听。
 * 幂等：重复调用不会重复注册。
 */
export function setupCarPlay() {
    if (started || !isCarPlayAvailable) {
        return;
    }
    started = true;

    const em = getEmitter();
    if (!em) {
        return;
    }

    em.addListener("CarPlayRequestTracks", (e: { sheetId?: string }) => {
        if (e?.sheetId) {
            pushTracks(e.sheetId);
        }
    });

    em.addListener("CarPlayPlayTrack", (e: { trackId?: string; sheetId?: string }) => {
        if (e?.trackId && e?.sheetId) {
            playTrack(e.trackId, e.sheetId);
        }
    });

    em.addListener("CarPlayControl", (e: { action?: string }) => {
        if (e?.action) {
            handleControl(e.action);
        }
    });

    /* 11142655：车机搜索请求 -> JS 联网搜索 */
    em.addListener("CarPlaySearch", (e: { query?: string }) => {
        if (e?.query) {
            handleSearch(e.query);
        }
    });

    // 连接时车机会主动发 requestSheets；RN 就绪后主动冲刷 pending 事件并先推一次，
    // 覆盖车机以 intent background 冷启动、RN bundle 晚到的时序竞态。
    try {
        NativeBridge?.carPlayJSReady?.();
    } catch (e) {
        errorLog("[CarPlay] carPlayJSReady", e);
    }
    pushSheets();

    /*
     * 11142655：注册完立刻推一次播放状态，让原生播放页能拿到初始值。
     * 后续（构建 B）会加定时器做实时刷新。
     */
    pushNowPlayingState();
    pushLyric();

    /*
     * 11142657：歌词异步加载 —— 切歌后歌词要等插件返回，
     * 所以用轮询兜底：每 2 秒检查一次歌词是否变了，变了就推。
     * （lyricManager 没有暴露事件订阅，轮询最稳）
     */
    let lastLyricSig = "";
    setInterval(() => {
        try {
            const lyricModule = require("@/core/lyricManager");
            const mgr = lyricModule.default ?? lyricModule;
            const state = mgr?.lyricState;
            if (!state || state.loading || !Array.isArray(state.lyrics)) {
                return;
            }
            /* 用「行数 + 首行时间」做签名，避免每 2 秒都推 */
            const sig = `${state.lyrics.length}|${state.lyrics[0]?.time ?? ""}|${state.lyrics[0]?.lrc ?? ""}`;
            if (sig !== lastLyricSig) {
                lastLyricSig = sig;
                pushLyric();
            }
        } catch (e) {
            /* 静默 */
        }
    }, 2000);

    /*
     * ============ 11142661：播放状态实时推送 ============
     *
     * 目的：让车机播放页的进度条走动、播放/暂停图标切换。
     *
     * 为什么用定时器：
     *   react-native-track-player 的 ProgressChanged 事件在
     *   某些版本/配置下不触发，而 getProgress() 一定可用。
     *   500ms 一次足够平滑，开销可忽略（只是读一个数字 + 过一次桥）。
     *
     * 去重：状态没变就不推（避免无意义过桥）。
     */
    let lastStateSig = "";
    setInterval(async () => {
        try {
            const music = TrackPlayer.currentMusic;
            const key = music?.id ?? "";
            let progress = 0;
            let isPlaying = 0;
            try {
                const p = await TrackPlayer.getProgress();
                progress = Math.floor(p?.position ?? 0);   /* 取整，减少变化频率 */
            } catch (e) {
                /* 未播放 */
            }
            try {
                const st = await TrackPlayer.getPlaybackState();
                isPlaying = st?.state === 3 ? 1 : 0;
            } catch (e) {
                /* 忽略 */
            }

            /* 签名：曲目 + 秒数 + 播放态 */
            const sig = `${key}|${progress}|${isPlaying}`;
            if (sig === lastStateSig) {
                return;
            }
            lastStateSig = sig;

            await pushNowPlayingState();
        } catch (e) {
            /* 静默，不打扰 */
        }
    }, 500);

    trace("[CarPlay] JS bridge started (search + state + lyric channels ready, 500ms state ticker)");
}

export default {
    setupCarPlay,
    isCarPlayAvailable,
    pushSheets,
    pushTracks,
    pushNowPlaying,
};
