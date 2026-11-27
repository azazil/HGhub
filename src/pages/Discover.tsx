import { useEffect, useRef, useState } from "react";
import { api, fmt } from "../api";
import { useStore } from "../store";
import type {
  HomeData, HomeVideo, Post, SiteCategory, TagsData, Topic, VideoCard,
} from "../types";
import { RowCard } from "../components/cards";
import { Empty, Img } from "../components/ui";
import { IChevR, ICompass, ITrophy } from "../icons";

function toCard(v: HomeVideo): VideoCard {
  return {
    id: v.id,
    title: v.title,
    cover: v.cover,
    description: v.desc,
    tags: v.tags || [],
    score: v.score || 0,
    episode_count: v.episode_count || 0,
    total_episodes: v.episode_count || 0,
    duration: v.duration,
    hot: v.hot,
    like_count: 0,
    collect_count: 0,
    comment_count: 0,
    is_finished: !!v.is_finished,
    is_original: 0,
  };
}

function Section({ title, sub, onMore, children }: {
  title: string;
  sub?: string;
  onMore?: () => void;
  children: React.ReactNode;
}) {
  return (
    <section className="mb-5">
      <div className="flex items-end justify-between px-4 mb-2">
        <div className="min-w-0">
          <div className="text-[15px] font-bold text-on leading-none">{title}</div>
          {sub && <div className="text-[10.5px] text-mut mt-1 truncate">{sub}</div>}
        </div>
        {onMore && (
          <button onClick={onMore} className="shrink-0 flex items-center gap-0.5 text-[11.5px] text-primary pressable">
            更多<IChevR size={13} />
          </button>
        )}
      </div>
      {children}
    </section>
  );
}

function Row({ videos, onOpen }: { videos: VideoCard[]; onOpen: (v: VideoCard) => void }) {
  if (!videos.length) return null;
  return (
    <div className="flex gap-2.5 overflow-x-auto scroll-x px-4 pb-1 snap-x" style={{ scrollPaddingLeft: 16 }}>
      {videos.map((v) => <RowCard key={v.id} v={v} onOpen={() => onOpen(v)} />)}
    </div>
  );
}

function PostRow({ posts, onOpen }: { posts: Post[]; onOpen: (p: Post) => void }) {
  if (!posts.length) return null;
  return (
    <div className="flex gap-2.5 overflow-x-auto scroll-x px-4 pb-1 snap-x">
      {posts.map((p) => (
        <button key={p.id} onClick={() => onOpen(p)} className="w-[190px] shrink-0 text-left pressable">
          <div className="relative w-full rounded-(--r-sm) overflow-hidden bg-s1 elev-1" style={{ paddingTop: "66%" }}>
            <Img src={p.cover} />
            <div className="absolute inset-x-0 bottom-0 h-1/2 bg-gradient-to-t from-black/80 to-transparent" />
            <span className="absolute bottom-1.5 right-2 text-[9px] text-white/85">{fmt(p.hot)} 热度</span>
          </div>
          <div className="text-[12px] text-on mt-1.5 leading-snug clamp-2">{p.title}</div>
        </button>
      ))}
    </div>
  );
}

export default function Discover({ active }: { active: boolean }) {
  const { push } = useStore();
  const [home, setHome] = useState<HomeData | null>(null);
  const [today, setToday] = useState<VideoCard[]>([]);
  const [hot, setHot] = useState<VideoCard[]>([]);
  const [original, setOriginal] = useState<VideoCard[]>([]);
  const [topics, setTopics] = useState<Topic[]>([]);
  const [tags, setTags] = useState<TagsData | null>(null);
  const [posts, setPosts] = useState<Post[]>([]);
  const [cats, setCats] = useState<SiteCategory[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [reload, setReload] = useState(0);
  const loadedRef = useRef(false);

  useEffect(() => {
    if (!active) return;
    if (loadedRef.current && reload === 0) return;
    loadedRef.current = true;
    let alive = true;
    setLoading(true);
    setError("");
    Promise.allSettled([
      api.home(),
      api.feedToday(1, 10),
      api.videosSorted("hot", 1, 10),
      api.videosOriginal(1, 10),
      api.topics(1, 20),
      api.tags(),
      api.feedPostToday(1, 6),
      api.categoriesVideo(),
    ]).then((results) => {
      if (!alive) return;
      const [h, t, ho, o, tp, tg, ps, cs] = results;
      if (h.status === "fulfilled") setHome(h.value);
      else setError((h.reason as Error)?.message || "加载失败");
      if (t.status === "fulfilled") setToday(t.value.items || []);
      if (ho.status === "fulfilled") setHot(ho.value.items || []);
      if (o.status === "fulfilled") setOriginal(o.value.items || []);
      if (tp.status === "fulfilled") setTopics(tp.value.items || []);
      if (tg.status === "fulfilled") setTags(tg.value);
      if (ps.status === "fulfilled") setPosts(ps.value.items || []);
      if (cs.status === "fulfilled") setCats(cs.value.items || []);
      setLoading(false);
    });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active, reload]);

  const openFeed = (ids: number[], index: number, title = "发现") => {
    if (!ids.length) return;
    push({
      kind: "feed",
      videoIds: ids,
      index: Math.max(0, Math.min(index, ids.length - 1)),
      title,
    });
  };

  const openCards = (videos: VideoCard[], v: VideoCard, title = "发现") =>
    openFeed(videos.map((x) => x.id), videos.findIndex((x) => x.id === v.id), title);

  const featured = (home?.featured || []).map(toCard);
  const latest = (home?.latest || []).map(toCard);
  const activeCatIds = new Set((home?.cate_rec || []).map((c) => c.cate_id));
  const activeCats = cats.filter((c) => activeCatIds.has(c.id));

  if (loading && !home) {
    return <div className="absolute inset-0 bg-bg flex items-center justify-center"><div className="w-9 h-9 spinner" /></div>;
  }
  if (!home && error) {
    return (
      <div className="absolute inset-0 bg-bg flex items-center justify-center">
        <Empty icon={<ICompass size={26} />} title="发现加载失败" sub={error} action="重试" onAction={() => setReload((n) => n + 1)} />
      </div>
    );
  }

  return (
    <div className="absolute inset-0 bg-bg flex flex-col">
      <div className="shrink-0 px-4 pb-2" style={{ paddingTop: "calc(var(--sat, 0px) + 14px)" }}>
        <div className="flex items-end justify-between">
          <div>
            <div className="text-[24px] font-bold text-on leading-none">发现</div>
            <div className="text-[11px] text-mut mt-1">今日更新 · 推荐 · 热门 · 专题 · 标签</div>
          </div>
          <button onClick={() => push({ kind: "ranks" })} className="flex items-center gap-1 h-8 px-3 rounded-(--r-ctl) bg-s2 text-[11.5px] text-on pressable">
            <ITrophy size={14} />排行榜
          </button>
        </div>
      </div>

      <div className="flex-1 scroll-y pb-24">
        {/* Banner */}
        {!!home?.banners?.length && (
          <div className="flex gap-3 overflow-x-auto scroll-x px-4 pb-3 snap-x">
            {home.banners.map((b) => (
              <button key={b.id} onClick={() => openFeed([b.video_id], 0, "发现")}
                className="relative w-[285px] shrink-0 rounded-(--r-md) overflow-hidden bg-s1 elev-1 text-left pressable"
                style={{ paddingTop: "52%" }}>
                <Img src={b.image} />
                <div className="absolute inset-0 bg-gradient-to-t from-black/85 via-black/20 to-transparent" />
                <div className="absolute inset-x-0 bottom-0 p-3">
                  <div className="text-[13px] font-semibold text-white leading-snug clamp-2">{b.title}</div>
                  {b.desc && <div className="text-[10px] text-white/70 mt-1 clamp-1">{b.desc}</div>}
                  {!!b.score && <div className="absolute right-3 top-3 px-1.5 py-0.5 rounded-md bg-black/45 text-[10px] text-white/90">{b.score.toFixed?.(1) ?? b.score}</div>}
                </div>
              </button>
            ))}
          </div>
        )}

        {!!today.length && (
          <Section title="今日更新" sub={`${today.length} 部新内容`} onMore={() => openFeed(today.map((v) => v.id), 0, "今日更新")}>
            <Row videos={today} onOpen={(v) => openCards(today, v, "今日更新")} />
          </Section>
        )}

        {!!featured.length && (
          <Section title="推荐" sub="编辑精选">
            <Row videos={featured} onOpen={(v) => openCards(featured, v, "推荐")} />
          </Section>
        )}

        {!!hot.length && (
          <Section title="热门" sub="按热度排序">
            <Row videos={hot} onOpen={(v) => openCards(hot, v, "热门")} />
          </Section>
        )}

        {!!original.length && (
          <Section title="原创" sub="官方原创内容">
            <Row videos={original} onOpen={(v) => openCards(original, v, "原创")} />
          </Section>
        )}

        {!!latest.length && (
          <Section title="最新" sub="刚刚更新">
            <Row videos={latest} onOpen={(v) => openCards(latest, v, "最新")} />
          </Section>
        )}

        {!!activeCats.length && (
          <Section title="分类" sub="短剧 · 漫剧">
            <div className="flex gap-2.5 overflow-x-auto scroll-x px-4 pb-1">
              {activeCats.map((c) => (
                <button key={c.id} onClick={() => push({ kind: "channel", cate: c.route, name: c.name })}
                  className="shrink-0 h-10 px-4 rounded-(--r-ctl) bg-s2 text-[12.5px] font-semibold text-on pressable">
                  {c.name}
                </button>
              ))}
            </div>
          </Section>
        )}

        {(home?.cate_rec || []).map((c) => {
          const videos = c.videos.map(toCard);
          if (!videos.length) return null;
          const route = cats.find((x) => x.id === c.cate_id)?.route;
          return (
            <Section key={c.cate_id} title={c.cate_name} onMore={route ? () => push({ kind: "channel", cate: route, name: c.cate_name }) : undefined}>
              <Row videos={videos} onOpen={(v) => openCards(videos, v, c.cate_name)} />
            </Section>
          );
        })}

        {!!topics.length && (
          <Section title="专题" sub={`${topics.length} 个专辑`}>
            <div className="flex gap-2.5 overflow-x-auto scroll-x px-4 pb-1 snap-x">
              {topics.map((t) => (
                <button key={t.id} onClick={() => push({ kind: "topic", slug: t.slug, title: t.title })}
                  className="relative w-[210px] shrink-0 rounded-(--r-md) overflow-hidden bg-s1 elev-1 text-left pressable"
                  style={{ paddingTop: "58%" }}>
                  <Img src={t.cover} />
                  <div className="absolute inset-0 bg-gradient-to-t from-black/85 via-black/20 to-transparent" />
                  <div className="absolute inset-x-0 bottom-0 p-2.5">
                    <div className="text-[12.5px] font-semibold text-white clamp-2">{t.title}</div>
                    {!!t.video_count && <div className="text-[10px] text-white/65 mt-1">{t.video_count} 部</div>}
                  </div>
                </button>
              ))}
            </div>
          </Section>
        )}

        {!!tags?.categories?.length && (
          <Section title="标签" sub="按题材和玩法浏览">
            <div className="px-4 space-y-3">
              {tags.categories.filter((c) => c.tags.length).map((c) => (
                <div key={c.id}>
                  <div className="text-[11.5px] font-semibold text-mut mb-1.5">{c.name}</div>
                  <div className="flex flex-wrap gap-1.5">
                    {c.tags.map((t) => (
                      <button key={`${c.id}-${t.name}`} onClick={() => push({ kind: "tag", tag: t.name, title: t.name })}
                        className="h-7 px-3 rounded-(--r-ctl) bg-s2 text-[11.5px] text-on pressable">
                        {t.name}
                      </button>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          </Section>
        )}

        {!!(posts.length) && (
          <Section title="吃瓜" sub="今日热门爆料">
            <PostRow posts={posts} onOpen={(p) => push({ kind: "post", id: p.id })} />
          </Section>
        )}

        {error && !!home && (
          <div className="px-4 pb-4 text-[11px] text-danger">{error}</div>
        )}
      </div>
    </div>
  );
}
