import { IAppConfig } from "@/types/core/config";
import { ITrackPlayer } from "@/types/core/trackPlayer";
import { IInjectable } from "@/types/infra";
import LyricParser, { IParsedLrcItem } from "@/utils/lrcParser";
import { getMediaExtraProperty, patchMediaExtra } from "@/utils/mediaExtra";
import { isSameMediaItem } from "@/utils/mediaUtils";
import minDistance from "@/utils/minDistance";
import { atom, getDefaultStore, useAtomValue } from "jotai";
import { Plugin } from "./pluginManager";

import pathConst from "@/constants/pathConst";
import LyricUtil from "@/native/lyricUtil";
import { checkAndCreateDir } from "@/utils/fileUtils";
import PersistStatus from "@/utils/persistStatus";
import CryptoJs from "crypto-js";
import { unlink, writeFile } from "react-native-fs";
import RNTrackPlayer, { Event } from "react-native-track-player";
import { TrackPlayerEvents } from "@/core.defination/trackPlayer";
import { IPluginManager } from "@/types/core/pluginManager";


/* ============ 11142656：歌词匹配放宽 ============ */

/**
 * 去掉标题里的常见后缀，提取「核心标题」。
 *
 * 例：
 *   晴天 (Live)        -> 晴天
 *   晴天（伴奏）        -> 晴天
 *   夜曲 - Remix       -> 夜曲
 *   七里香 Live版       -> 七里香
 */
function coreTitle(raw?: string): string {
    if (!raw) {
        return "";
    }
    let s = raw.trim();
    // 去掉中英文括号及其内容
    s = s.replace(/[（(\[【][^）)\]】]*[）)\]】]/g, "");
    // 去掉 " - xxx" 之后的部分
    s = s.replace(/\s+-\s+.*$/, "");
    // 去掉常见的版本词（不含空格的情况）
    s = s.replace(/(live|remix|伴奏|纯音乐|instrumental|cover|翻唱)/gi, "");
    return s.trim().toLowerCase();
}

/**
 * 把歌手串拆成集合。
 * 支持分隔符：/ 、 & , ； 空格
 *
 * 例：
 *   周杰伦/JVR       -> [周杰伦, jvr]
 *   周杰伦 & 费玉清   -> [周杰伦, 费玉清]
 */
function artistSet(raw?: string): string[] {
    if (!raw) {
        return [];
    }
    return raw
        .split(/[\/、&,，;；]/)
        .map((x) => x.trim().toLowerCase())
        .filter((x) => x.length > 0);
}

/**
 * 两个歌手串是否有交集（任一相同即可）。
 */
function artistOverlap(a?: string, b?: string): boolean {
    const sa = artistSet(a);
    const sb = artistSet(b);
    if (!sa.length || !sb.length) {
        return false;
    }
    return sa.some((x) => sb.includes(x));
}

/**
 * 是否是「伴奏/纯音乐」这类特殊版本 —— 这类不拿来匹配原曲歌词。
 */
function isInstrumental(raw?: string): boolean {
    if (!raw) {
        return false;
    }
    return /(伴奏|纯音乐|instrumental|karaoke|off\s*vocal)/i.test(raw);
}

interface ILyricState {
    loading: boolean;
    lyrics: IParsedLrcItem[];
    hasTranslation: boolean;
    meta?: Record<string, string>;
}

const defaultLyricState = {
    loading: true,
    lyrics: [],
    hasTranslation: false,
};

const lyricStateAtom = atom<ILyricState>(defaultLyricState);
const currentLyricItemAtom = atom<IParsedLrcItem | null>(null);


class LyricManager implements IInjectable {

    private trackPlayer!: ITrackPlayer;
    private appConfig!: IAppConfig;
    private pluginManager!: IPluginManager;

    private lyricParser: LyricParser | null = null;


    get currentLyricItem() {
        return getDefaultStore().get(currentLyricItemAtom);
    }

    get lyricState() {
        return getDefaultStore().get(lyricStateAtom);
    }

    injectDependencies(trackPlayerService: ITrackPlayer, appConfigService: IAppConfig, pluginManager: IPluginManager): void {
        this.trackPlayer = trackPlayerService;
        this.appConfig = appConfigService;
        this.pluginManager = pluginManager;
    }

    setup() {
        // 更新歌词
        this.trackPlayer.on(TrackPlayerEvents.CurrentMusicChanged, (musicItem) => {
            this.refreshLyric(true, true);

            if (this.appConfig.getConfig("lyric.showStatusBarLyric")) {
                if (musicItem) {
                    LyricUtil.setStatusBarLyricText(
                        `${musicItem.title} - ${musicItem.artist}`,);
                } else {
                    LyricUtil.setStatusBarLyricText("MusicFree");
                }
            }
        });

        RNTrackPlayer.addEventListener(Event.PlaybackProgressUpdated, evt => {
            const parser = this.lyricParser;
            if (!parser || !this.trackPlayer.isCurrentMusic(parser.musicItem)) {
                return;
            }

            const currentLyricItem = getDefaultStore().get(currentLyricItemAtom);
            const newLyricItem = parser.getPosition(evt.position);


            if (currentLyricItem?.lrc !== newLyricItem?.lrc) {
                // 更新当前歌词状态
                getDefaultStore().set(currentLyricItemAtom, newLyricItem ?? null);

                // 更新状态栏歌词
                const showTranslation = PersistStatus.get("lyric.showTranslation");

                if (this.appConfig.getConfig("lyric.showStatusBarLyric")) {
                    LyricUtil.setStatusBarLyricText(
                        (newLyricItem?.lrc ?? "") +
                        (showTranslation
                            ? `\n${newLyricItem?.translation ?? ""}`
                            : ""),
                    );
                }
            }
        });


        if (this.appConfig.getConfig("lyric.showStatusBarLyric")) {
            const statusBarLyricConfig = {
                topPercent: this.appConfig.getConfig("lyric.topPercent"),
                leftPercent: this.appConfig.getConfig("lyric.leftPercent"),
                align: this.appConfig.getConfig("lyric.align"),
                color: this.appConfig.getConfig("lyric.color"),
                backgroundColor: this.appConfig.getConfig("lyric.backgroundColor"),
                widthPercent: this.appConfig.getConfig("lyric.widthPercent"),
                fontSize: this.appConfig.getConfig("lyric.fontSize"),
            };
            LyricUtil.showStatusBarLyric(
                "MusicFree",
                statusBarLyricConfig ?? {}
            );
        }

        this.refreshLyric(true);
    }

    associateLyric(musicItem: IMusic.IMusicItem, linkToMusicItem: ICommon.IMediaBase) {
        if (!musicItem || !linkToMusicItem) {
            return false;
        }

        // 如果当前音乐项和关联的音乐项相同，则不需要重新关联
        if (isSameMediaItem(musicItem, linkToMusicItem)) {
            patchMediaExtra(musicItem, {
                associatedLrc: undefined,
            });
            return false;
        } else {
            patchMediaExtra(musicItem, {
                associatedLrc: linkToMusicItem,
            });
            if (this.trackPlayer.isCurrentMusic(musicItem)) {
                this.refreshLyric(false);
            }
            return true;
        }
    }

    unassociateLyric(musicItem: IMusic.IMusicItem) {
        if (!musicItem) {
            return;
        }

        patchMediaExtra(musicItem, {
            associatedLrc: undefined,
        });

        if (this.trackPlayer.isCurrentMusic(musicItem)) {
            this.refreshLyric(false);
        }
    }

    async uploadLocalLyric(musicItem: IMusic.IMusicItem, lyricContent: string, type: "raw" | "translation" = "raw") {
        if (!musicItem) {
            return;
        }

        const platformHash = CryptoJs.MD5(musicItem.platform).toString(
            CryptoJs.enc.Hex,
        );
        const idHash: string = CryptoJs.MD5(musicItem.id).toString(
            CryptoJs.enc.Hex,
        );

        // 检查是否缓存文件夹存在
        await checkAndCreateDir(pathConst.localLrcPath + platformHash);
        await writeFile(pathConst.localLrcPath +
            platformHash +
            "/" +
            idHash +
            (type === "raw" ? "" : ".tran") +
            ".lrc", lyricContent, "utf8");

        if (this.trackPlayer.isCurrentMusic(musicItem)) {
            this.refreshLyric(false, false);
        }
    }

    async removeLocalLyric(musicItem: IMusic.IMusicItem) {
        if (!musicItem) {
            return;
        }

        const platformHash = CryptoJs.MD5(musicItem.platform).toString(
            CryptoJs.enc.Hex,
        );
        const idHash: string = CryptoJs.MD5(musicItem.id).toString(
            CryptoJs.enc.Hex,
        );

        const basePath =
            pathConst.localLrcPath + platformHash + "/" + idHash;

        await unlink(basePath + ".lrc").catch(() => { });
        await unlink(basePath + ".tran.lrc").catch(() => { });

        if (this.trackPlayer.isCurrentMusic(musicItem)) {
            this.refreshLyric(false, false);
        }

    }


    updateLyricOffset(musicItem: IMusic.IMusicItem, offset: number) {
        if (!musicItem) {
            return;
        }

        // 更新歌词偏移
        patchMediaExtra(musicItem, {
            lyricOffset: offset,
        });

        if (this.trackPlayer.isCurrentMusic(musicItem)) {
            this.refreshLyric(true, false);
        }
    }

    private setLyricAsLoadingState() {
        getDefaultStore().set(lyricStateAtom, {
            loading: true,
            lyrics: [],
            hasTranslation: false,
        });
        getDefaultStore().set(currentLyricItemAtom, null);
    }

    private setLyricAsNoLyricState() {
        getDefaultStore().set(lyricStateAtom, {
            loading: false,
            lyrics: [],
            hasTranslation: false,
        });
        getDefaultStore().set(currentLyricItemAtom, null);
        if (this.appConfig.getConfig("lyric.showStatusBarLyric")) {
            const musicItem = this.trackPlayer.currentMusic;
            LyricUtil.setStatusBarLyricText(musicItem ? `${musicItem.title} - ${musicItem.artist}` : "MusicFree");
        }
    }

    private async refreshLyric(skipFetchLyricSourceIfSame: boolean = true, ignoreProgress: boolean = false) {
        const currentMusicItem = this.trackPlayer.currentMusic;

        // 如果没有当前音乐项，重置歌词状态
        if (!currentMusicItem) {
            this.setLyricAsNoLyricState();
            return;
        }

        try {
            let lrcSource: ILyric.ILyricSource | null;

            if (skipFetchLyricSourceIfSame && this.lyricParser && this.trackPlayer.isCurrentMusic(this.lyricParser.musicItem)) {
                lrcSource = this.lyricParser.lyricSource ?? null;
            } else {
                // 重置歌词状态
                this.setLyricAsLoadingState();

                lrcSource = (await this.pluginManager.getByMedia(currentMusicItem)?.methods?.getLyric(currentMusicItem)) ?? null;
            }

            // 切换到其他歌曲了, 直接返回
            if (!this.trackPlayer.isCurrentMusic(currentMusicItem)) {
                return;
            }

            // 如果歌词源不存在，并且开启自动搜索歌词
            /*
             * 11142656：默认开启。
             *
             * getConfig 未设置时返回 undefined（不是 false），
             * 之前 undefined 会被当成假值，导致自动搜歌词永远不触发。
             *
             * 改成 !== false —— 只有用户明确关掉才跳过。
             */
            if (!lrcSource && this.appConfig.getConfig("lyric.autoSearchLyric") !== false) {
                // 重置歌词状态
                this.setLyricAsLoadingState();

                lrcSource = await this.searchSimilarLyric(currentMusicItem);
            }

            // 切换到其他歌曲了, 直接返回
            if (!this.trackPlayer.isCurrentMusic(currentMusicItem)) {
                return;
            }

            // 如果源不存在，恢复默认设置
            if (!lrcSource) {
                this.setLyricAsNoLyricState();
                this.lyricParser = null;
                return;
            }

            this.lyricParser = new LyricParser(lrcSource.rawLrc!, {
                extra: {
                    offset: (getMediaExtraProperty(currentMusicItem, "lyricOffset") || 0) * -1,
                },
                musicItem: currentMusicItem,
                lyricSource: lrcSource,
                translation: lrcSource.translation,
            });

            getDefaultStore().set(lyricStateAtom, {
                loading: false,
                lyrics: this.lyricParser.getLyricItems(),
                hasTranslation: !!lrcSource.translation,
                meta: this.lyricParser.getMeta(),
            });

            const currentLyric = ignoreProgress ? (this.lyricParser.getLyricItems()?.[0] ?? null) : this.lyricParser.getPosition((await this.trackPlayer.getProgress()).position);
            getDefaultStore().set(currentLyricItemAtom, currentLyric || null);

            if (this.appConfig.getConfig("lyric.showStatusBarLyric")) {
                if (currentLyric) {
                    LyricUtil.setStatusBarLyricText(
                        (currentLyric?.lrc ?? "") +
                        (this.lyricParser.hasTranslation
                            ? `\n${currentLyric?.translation ?? ""}`
                            : ""),
                    );
                } else {
                    const musicItem = this.trackPlayer.currentMusic;
                    LyricUtil.setStatusBarLyricText(musicItem ? `${musicItem.title} - ${musicItem.artist}` : "MusicFree");
                }
            }
        } catch (err) {
            if (this.trackPlayer.isCurrentMusic(currentMusicItem)) {
                this.lyricParser = null;
                this.setLyricAsNoLyricState();
            }
        }
    }

    /**
     * 检索最接近的歌词
     * @param musicItem 
     * @returns 
     */
    private async searchSimilarLyric(musicItem: IMusic.IMusicItem) {
        const keyword = musicItem.alias || musicItem.title;
        const plugins = this.pluginManager.getSearchablePlugins("lyric");

        let distance = Infinity;
        let minDistanceMusicItem;
        let targetPlugin: Plugin | null = null;

        for (let plugin of plugins) {
            // 如果插件不是当前音乐的插件，或者当前音乐不是正在播放的音乐，则跳过
            if (
                !this.trackPlayer.isCurrentMusic(musicItem)
            ) {
                return null;
            }

            if (plugin.name === musicItem.platform) {
                // 如果插件是当前音乐的插件，则跳过
                continue;
            }

            const results = await plugin.methods
                .search(keyword, 1, "lyric")
                .catch(() => null);

            // 取前两个
            const firstTwo = results?.data?.slice(0, 2) || [];

            /*
             * 11142656：分层匹配（放宽但带安全约束）。
             *
             * 原逻辑只有「标题+歌手完全相等」才算命中，条件过严，
             * 标题带 (Live)/(Remix)、歌手写成 "周杰伦/JVR" 就匹配不到。
             *
             * 三层：
             *   第1层 distance=0  完全相等        -> 直接用，停止搜索
             *   第2层 distance=1  核心标题相同 + 歌手有交集
             *   第3层 distance=2  标题包含 + 歌手有交集
             *
             * 安全约束：
             *   - 第2/3层必须歌手有交集（不能只标题像）
             *   - 跳过「伴奏/纯音乐」候选（不给原曲配伴奏歌词）
             *   - 最多采用 distance<=2，超了放弃（宁可没歌词也不给错的）
             */
            for (let item of firstTwo) {
                /* 跳过伴奏/纯音乐候选 */
                if (isInstrumental(item.title)) {
                    continue;
                }

                const exactTitle = item.title === keyword;
                const exactArtist = item.artist === musicItem.artist;

                /* 第1层：完全相等 */
                if (exactTitle && exactArtist) {
                    distance = 0;
                    minDistanceMusicItem = item;
                    targetPlugin = plugin;
                    break;
                }

                /* 后续层必须有歌手交集 */
                if (!artistOverlap(item.artist, musicItem.artist)) {
                    continue;
                }

                const ct1 = coreTitle(item.title);
                const ct2 = coreTitle(keyword) || coreTitle(musicItem.title);

                /* 第2层：核心标题相同 */
                if (ct1.length > 0 && ct1 === ct2) {
                    if (1 < distance) {
                        distance = 1;
                        minDistanceMusicItem = item;
                        targetPlugin = plugin;
                    }
                    continue;
                }

                /* 第3层：标题互相包含 */
                if (
                    ct1.length > 1 &&
                    ct2.length > 1 &&
                    (ct1.includes(ct2) || ct2.includes(ct1))
                ) {
                    if (2 < distance) {
                        distance = 2;
                        minDistanceMusicItem = item;
                        targetPlugin = plugin;
                    }
                    continue;
                }

                /* 兜底：原来的编辑距离，但加上限（>2 不采用） */
                const dist =
                    minDistance(keyword, musicItem.title) +
                    minDistance(item.artist, musicItem.artist);
                if (dist < distance && dist <= 2) {
                    distance = dist;
                    minDistanceMusicItem = item;
                    targetPlugin = plugin;
                }
            }

            if (distance === 0) {
                break;
            }
        }

        /*
         * 11142656：距离上限 2。
         * 超过说明候选差异太大，宁可返回 null（显示无歌词），
         * 也不给用户配错版本的歌词。
         */
        if (minDistanceMusicItem && targetPlugin && distance <= 2) {
            return await targetPlugin.methods
                .getLyric(minDistanceMusicItem)
                .catch(() => null);
        }

        return null;
    }

}

const lyricManager = new LyricManager();
export default lyricManager;


export const useLyricState = () => useAtomValue(lyricStateAtom);
export const useCurrentLyricItem = () => useAtomValue(currentLyricItemAtom);