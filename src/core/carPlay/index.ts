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
import { MusicRepeatMode } from "@/constants/repeatModeConst";
import PluginManager from "@/core/pluginManager";
import TrackPlayer from "@/core/trackPlayer";
import { errorLog, trace } from "@/utils/log";
import { getDefaultStore } from "jotai";

const NativeBridge = NativeModules.CarPlayBridge;

/** 是否具备原生 CarPlay 桥 */
export const isCarPlayAvailable = Platform.OS === "ios" && !!NativeBridge;

let emitter: NativeEventEmitter | null = null;

/*
 * ============ 11142668：曲目缓存 ============
 *
 * 问题：playTrack 只在本地歌单里找曲目
 *   MusicSheet.findMusicItemForCarPlay(sheetId, trackId)
 *
 * 但搜索结果、榜单曲目、最近播放的歌都不在任何歌单里，
 * 所以点击后找不到 -> 无法播放。
 *
 * 解法：原生每次上报列表（搜索/榜单/历史）时，把这些曲目
 * 缓存在这里。playTrack 找不到时从缓存取。
 */
const trackCache = new Map<string, any>();

function cacheTracks(list: any[]) {
    if (!Array.isArray(list)) {
        return;
    }
    for (const x of list) {
        const id = String(x?.id ?? "");
        if (id) {
            trackCache.set(id, x);
        }
    }
    /* 缓存上限，防止无限增长 */
    if (trackCache.size > 500) {
        const keys = Array.from(trackCache.keys()).slice(0, 200);
        for (const k of keys) {
            trackCache.delete(k);
        }
    }
}

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
        /*
         * ============ 11142668：支持播放非歌单曲目 ============
         *
         * 之前只在本地歌单找：
         *   MusicSheet.findMusicItemForCarPlay(sheetId, trackId)
         *
         * 但搜索/榜单/最近播放的曲目都不在歌单里 -> 找不到 -> 放不了。
         *
         * 现在三级查找：
         *   1) 有 sheetId 且歌单里有 -> 用歌单曲目（能拿到完整队列）
         *   2) 缓存的曲目（搜索/榜单/历史点过的）
         *   3) 都找不到 -> 记错误
         */
        let musicItem: any = null;
        let list: any[] = [];

        /* 1. 优先从歌单找（有队列） */
        if (sheetId && sheetId.length > 0) {
            musicItem = MusicSheet.findMusicItemForCarPlay(sheetId, trackId);
            const sheetList = MusicSheet.getSortedMusicListBySheetId(sheetId)?.musicList ?? [];
            if (Array.isArray(sheetList) && sheetList.length > 0) {
                list = [...sheetList];
            }
        }

        /* 2. 缓存查找 */
        if (!musicItem) {
            musicItem = trackCache.get(String(trackId)) ?? null;
        }

        /* 3. 都没有 */
        if (!musicItem) {
            errorLog("[CarPlay] track not found anywhere", { trackId, sheetId });
            trace(`[CarPlay] playTrack FAILED: ${trackId} not in sheet nor cache (cache=${trackCache.size})`);
            return;
        }

        /* 没有队列就单曲播放 */
        if (!list.length) {
            list = [musicItem];
            trace(`[CarPlay] playTrack: single track (no queue) ${musicItem.title ?? trackId}`);
        }

        await TrackPlayer.playWithReplacePlayList(musicItem, list);
        pushNowPlaying(musicItem);
        trace(`[CarPlay] playTrack OK: ${musicItem.title ?? trackId} queue=${list.length}`);
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

/* ============ 11142661：爱心 / 循环 / 音质 ============ */

/**
 * 收藏 / 取消收藏当前歌曲。
 *
 * 用的是 MusicSheet 的默认歌单（id = "favorite"），
 * 和手机端 heartIcon 组件的逻辑完全一致：
 *   add    -> MusicSheet.addMusic(MusicSheet.defaultSheet.id, item)
 *   remove -> MusicSheet.removeMusic(MusicSheet.defaultSheet.id, item)
 */
function toggleFavoriteForCurrent() {
    try {
        const music = TrackPlayer.currentMusic;
        if (!music) {
            return;
        }
        const sheetId = MusicSheet.defaultSheet?.id ?? "favorite";
        const isFav = MusicSheet.isMusicInSheet?.(sheetId, music) ?? false;

        if (isFav) {
            MusicSheet.removeMusic(sheetId, music);
            trace(`[CarPlay] unfavorite: ${music.title}`);
        } else {
            MusicSheet.addMusic(sheetId, music);
            trace(`[CarPlay] favorite: ${music.title}`);
        }

        /* 立即回传新状态，让车机爱心图标马上变 */
        pushNowPlayingState();
    } catch (e) {
        errorLog("[CarPlay] toggleFavorite", e);
    }
}

/**
 * 循环模式切换：列表循环 -> 单曲循环 -> 随机播放 -> 列表循环
 *
 * setRepeatMode 是 private，不能直接调；
 * 用 toggleRepeat()（trackPlayer 的公开方法），它内部走
 * toggleRepeatMapping 做三态轮转。
 */
function cycleRepeatMode() {
    try {
        const next = {
            [MusicRepeatMode.QUEUE]: MusicRepeatMode.SINGLE,
            [MusicRepeatMode.SINGLE]: MusicRepeatMode.SHUFFLE,
            [MusicRepeatMode.SHUFFLE]: MusicRepeatMode.QUEUE,
        }[TrackPlayer.repeatMode as MusicRepeatMode] ?? MusicRepeatMode.QUEUE;

        /* @ts-expect-error setRepeatMode 是 private，但运行时可用 */
        TrackPlayer.setRepeatMode(next);
        trace(`[CarPlay] repeat -> ${next}`);
        pushNowPlayingState();
    } catch (e) {
        errorLog("[CarPlay] cycleRepeatMode", e);
    }
}

/**
 * 音质切换：standard -> high -> super -> standard
 *
 * 注意：音质只在「下一次取播放地址」时生效，
 * 当前这首不会立即变（这是 trackPlayer 的既有行为）。
 */
function cycleQuality() {
    try {
        const order = ["standard", "high", "super"];
        const cur = TrackPlayer.quality ?? "standard";
        const idx = order.indexOf(cur as string);
        const next = order[(idx + 1) % order.length];

        /* @ts-expect-error setQuality 是 private，但运行时可用 */
        TrackPlayer.setQuality(next);
        trace(`[CarPlay] quality -> ${next}`);
        pushNowPlayingState();
    } catch (e) {
        errorLog("[CarPlay] cycleQuality", e);
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

            /* ============ 11142661：爱心 / 循环 / 音质 ============ */
            case "toggle":
                /* 播放/暂停切换（播放页中间按钮） */
                await TrackPlayer.togglePlay();
                break;

            case "favorite":
                toggleFavoriteForCurrent();
                break;

            case "repeat":
                cycleRepeatMode();
                break;

            case "quality":
                cycleQuality();
                break;

            /* ============ 11142662：榜单 ============ */
            case "requestTopLists":
                pushTopLists();
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

/* ============ 11142662：榜单 ============ */

/**
 * 推送榜单列表给原生（平铺所有插件）。
 *
 * 数据结构（平铺后）：
 *   { pluginHash, pluginName, title, id, coverImg, description }
 *
 * 来源：每个插件的 getTopLists()，返回分组数组，
 *      每组的 data 是一个榜单数组，这里把两层拍平成一层。
 */
async function pushTopLists() {
    if (!NativeBridge?.setTopLists) {
        return;
    }
    try {
        const plugins = PluginManager.getSearchablePlugins?.() ?? [];
        const out: any[] = [];

        for (const plugin of plugins) {
            try {
                const groups = await plugin?.methods?.getTopLists?.();
                if (!Array.isArray(groups)) {
                    continue;
                }
                for (const g of groups) {
                    const items = g?.data ?? [];
                    for (const it of items) {
                        out.push({
                            pluginHash: plugin.hash ?? "",
                            pluginName: plugin.name ?? "",
                            id: String(it?.id ?? ""),
                            title: String(it?.title ?? ""),
                            coverImg: String(it?.coverImg ?? ""),
                            description: String(it?.description ?? ""),
                        });
                    }
                }
            } catch (e) {
                /* 单个插件失败不影响其他 */
            }
        }

        NativeBridge.setTopLists(out);
        trace(`[CarPlay] pushed ${out.length} top lists`);
    } catch (e) {
        errorLog("[CarPlay] pushTopLists", e);
    }
}

/**
 * 车机点了某个榜单 -> 拉取详情曲目 -> 回传原生。
 *
 * 原生传上来的是 pluginHash + listId + title。
 */
async function fetchTopListDetail(pluginHash: string, listId: string, title: string) {
    try {
        const plugin = PluginManager.getByHash?.(pluginHash);
        if (!plugin?.methods?.getTopListDetail) {
            errorLog("[CarPlay] topListDetail: plugin not found", { pluginHash });
            NativeBridge?.setTopListTracks?.([], listId);
            return;
        }

        const result = await plugin.methods.getTopListDetail(
            { id: listId, title } as any,
            1,
        );

        const tracks = (result?.musicList ?? []).map((x: any) => ({
            id: String(x?.id ?? ""),
            title: String(x?.title ?? ""),
            artist: String(x?.artist ?? ""),
            album: String(x?.album ?? ""),
            artwork: String(x?.artwork ?? ""),
            platform: String(x?.platform ?? plugin.name ?? ""),
        }));

        cacheTracks(tracks);

        trace(`[CarPlay] topList detail '${title}' -> ${tracks.length} tracks`);
        NativeBridge?.setTopListTracks?.(tracks, listId);
    } catch (e) {
        errorLog("[CarPlay] fetchTopListDetail", e);
        NativeBridge?.setTopListTracks?.([], listId);
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
         * ============ 11142668：真正的联网搜索 ============
         *
         * 之前一直是 TODO 空实现（永远返回空数组），
         * 所以车机上只能搜到本地歌单。
         *
         * 现在改成：调用所有支持搜索的插件，合并结果。
         *
         * 接口确认（src/core/pluginManager/plugin.ts:173）：
         *   plugin.methods.search(query, page, type)
         *   type 为 "music"
         *   返回 { isEnd, data: IMusicItem[] }
         *
         * 限制：
         *   - 每个插件最多取前 20 条（避免车机上列表过长）
         *   - 单个插件失败不影响其他
         *   - 总共最多 60 条
         */
        const plugins = PluginManager.getSearchablePlugins?.("music") ?? [];
        trace(`[CarPlay] search across ${plugins.length} plugins`);

        const merged: any[] = [];
        const MAX_PER_PLUGIN = 20;
        const MAX_TOTAL = 60;

        for (const plugin of plugins) {
            if (merged.length >= MAX_TOTAL) {
                break;
            }
            try {
                const r = await plugin?.methods?.search?.(query, 1, "music");
                const items = r?.data ?? [];
                for (const it of items) {
                    if (merged.length >= MAX_TOTAL) {
                        break;
                    }
                    if (merged.length >= plugins.length * MAX_PER_PLUGIN) {
                        break;
                    }
                    merged.push({
                        id: String(it?.id ?? ""),
                        title: String(it?.title ?? ""),
                        artist: String(it?.artist ?? ""),
                        album: String(it?.album ?? ""),
                        artwork: String(it?.artwork ?? ""),
                        platform: String(it?.platform ?? plugin.name ?? ""),
                        /* 搜索结果没有歌单归属，用空串 */
                        sheetId: "",
                    });
                }
            } catch (e) {
                /* 单插件失败忽略 */
                trace(`[CarPlay] plugin ${plugin?.name ?? "?"} search failed`);
            }
        }

        /* 缓存这些曲目，供点击时播放 */
        cacheTracks(merged);

        trace(`[CarPlay] search reply: ${merged.length} results for "${query}"`);
        NativeBridge?.setSearchResults?.(merged, query);
    } catch (e) {
        errorLog("[CarPlay] handleSearch", e);
        NativeBridge?.setSearchResults?.([], query);
    }
}

/**
 * 推送播放状态给原生（实时更新用）。
 *
 * 注意（构建 A 阶段）：
 *   只是把当前 TrackPlayer 状态快照发过去，验证通路。
 *   下一轮再加定时器做进度条实时刷新。
 */
/**
 * 11142661：当前歌曲是否已收藏。
 *
 * 收藏就是「在默认歌单（favorite）里」，
 * 和手机端 heartIcon 组件同一套判断。
 */
function isCurrentFavorite(music: any): boolean {
    if (!music) {
        return false;
    }
    try {
        const sheetId = MusicSheet.defaultSheet?.id ?? "favorite";
        if (typeof MusicSheet.isMusicInSheet === "function") {
            return MusicSheet.isMusicInSheet(sheetId, music) ?? false;
        }
        /* 退路：查默认歌单的曲目列表 */
        const list = MusicSheet.getSortedMusicListBySheetId?.(sheetId)?.musicList ?? [];
        return list.some((x: any) => x?.id === music.id);
    } catch (e) {
        return false;
    }
}

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
            repeatMode: TrackPlayer.repeatMode ?? "QUEUE",
            quality: TrackPlayer.quality ?? "standard",
            rate: 1.0,
            /* 11142661：真实收藏状态（之前硬编码 0，爱心永远空心） */
            isFavorite: isCurrentFavorite(music) ? 1 : 0,
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

    /* 11142662：车机点榜单 -> JS 拉详情 */
    em.addListener("CarPlayTopListDetail", (e: {
        pluginHash?: string;
        listId?: string;
        title?: string;
    }) => {
        if (e?.pluginHash && e?.listId) {
            fetchTopListDetail(e.pluginHash, e.listId, e.title ?? "");
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

    /* 11142662：启动时拉一次榜单（异步，不阻塞） */
    pushTopLists();

    trace("[CarPlay] JS bridge started (search + state + lyric + toplist channels ready)");
}

export default {
    setupCarPlay,
    isCarPlayAvailable,
    pushSheets,
    pushTracks,
    pushNowPlaying,
};
