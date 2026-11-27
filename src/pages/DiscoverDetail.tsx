import { useCallback, useEffect, useState } from "react";
import { api } from "../api";
import { useStore } from "../store";
import type { Topic, VideoCard } from "../types";
import { Masonry } from "../components/cards";
import { Empty, Img } from "../components/ui";
import { IBack, IChevR } from "../icons";

function Header({ title, sub, onBack }: { title: string; sub?: string; onBack: () => void }) {
  return (
    <div className="shrink-0 bg-s1 relative overflow-hidden" style={{ paddingTop: "var(--sat, 0px)" }}>
      <div className="absolute inset-0 pointer-events-none" style={{ background: "radial-gradient(80% 120% at 100% 0%, var(--p-pc) 0%, transparent 60%)", opacity: 0.28 }} />
      <div className="relative flex items-center gap-2 px-3 py-2.5">
        <button onClick={onBack} aria-label="返回" className="w-10 h-10 rounded-full flex items-center justify-center text-on pressable"><IBack size={20} /></button>
        <div className="min-w-0">
          <div className="text-[16px] font-bold text-on truncate">{title}</div>
          {sub && <div className="text-[10.5px] text-mut truncate">{sub}</div>}
        </div>
      </div>
    </div>
  );
}

export function TopicPage({ slug, title, onBack, wide }: {
  slug: string; title: string; onBack: () => void; wide: boolean;
}) {
  const { push } = useStore();
  const [topic, setTopic] = useState<Topic | null>(null);
  const [videos, setVideos] = useState<VideoCard[]>([]);
  const [related, setRelated] = useState<Topic[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    let alive = true;
    setLoading(true);
    api.topic(slug)
      .then((r) => {
        if (!alive) return;
        setTopic(r.topic);
        setVideos(r.videos?.items || []);
        setRelated(r.related || []);
      })
      .catch((e) => { if (alive) setError((e as Error).message || "加载失败"); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [slug]);

  const open = (v: VideoCard) => {
    push({
      kind: "feed",
      videoIds: videos.map((x) => x.id),
      index: Math.max(0, videos.findIndex((x) => x.id === v.id)),
      title: title || topic?.title || "专题",
    });
  };

  return (
    <div className="absolute inset-0 bg-bg flex flex-col">
      <Header title={title || topic?.title || "专题"} sub={topic ? `${topic.video_count || videos.length} 部 · ${topic.title}` : undefined} onBack={onBack} />
      <div className="flex-1 scroll-y pb-10">
        {loading ? (
          <div className="flex items-center justify-center py-20"><div className="w-9 h-9 spinner" /></div>
        ) : error && !videos.length ? (
          <Empty icon={<IBack size={26} />} title="专题加载失败" sub={error} />
        ) : (
          <>
            {topic && (
              <div className="px-4 py-3">
                <div className="text-[13px] text-mut leading-relaxed">{topic.intro}</div>
              </div>
            )}
            <div className={`px-3 ${wide ? "max-w-[980px] mx-auto" : ""}`}>
              <Masonry videos={videos} onOpen={open} wide={wide} gap="gap-1.5" />
            </div>
            {!!related.length && (
              <div className="mt-5">
                <div className="px-4 text-[13.5px] font-bold text-on mb-2">相关专题</div>
                <div className="flex gap-2.5 overflow-x-auto scroll-x px-4 pb-3">
                  {related.map((t) => (
                    <button key={t.id} onClick={() => push({ kind: "topic", slug: t.slug, title: t.title })}
                      className="relative w-[190px] shrink-0 rounded-(--r-md) overflow-hidden bg-s1 elev-1 text-left pressable"
                      style={{ paddingTop: "58%" }}>
                      <Img src={t.cover} />
                      <div className="absolute inset-0 bg-gradient-to-t from-black/85 to-transparent" />
                      <div className="absolute inset-x-0 bottom-0 p-2.5 text-[12px] font-semibold text-white clamp-2">{t.title}</div>
                    </button>
                  ))}
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

export function TagPage({ tag, title, onBack, wide }: {
  tag: string; title: string; onBack: () => void; wide: boolean;
}) {
  const { push } = useStore();
  const [videos, setVideos] = useState<VideoCard[]>([]);
  const [page, setPage] = useState(1);
  const [pages, setPages] = useState(1);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async (p: number) => {
    setLoading(true);
    setError("");
    try {
      const res = await api.videosByTag(tag, p, 20);
      setVideos((prev) => {
        const seen = new Set(prev.map((x) => x.id));
        return [...prev, ...(res.items || []).filter((x) => !seen.has(x.id))];
      });
      setPage(res.pagination?.page || p);
      setPages(res.pagination?.pages || p);
    } catch (e) {
      setError((e as Error).message || "加载失败");
    } finally {
      setLoading(false);
    }
  }, [tag]);

  useEffect(() => { void load(1); }, [load]);

  const open = (v: VideoCard) => {
    push({
      kind: "feed",
      videoIds: videos.map((x) => x.id),
      index: Math.max(0, videos.findIndex((x) => x.id === v.id)),
      title: title || tag,
    });
  };

  return (
    <div className="absolute inset-0 bg-bg flex flex-col">
      <Header title={`#${title || tag}`} sub={`共 ${videos.length} 部`} onBack={onBack} />
      <div className="flex-1 scroll-y pb-10">
        {loading && !videos.length ? (
          <div className="flex items-center justify-center py-20"><div className="w-9 h-9 spinner" /></div>
        ) : error && !videos.length ? (
          <Empty icon={<IBack size={26} />} title="标签加载失败" sub={error} action="重试" onAction={() => void load(1)} />
        ) : !videos.length ? (
          <Empty icon={<IBack size={26} />} title="暂无内容" />
        ) : (
          <div className={`px-3 ${wide ? "max-w-[980px] mx-auto" : ""}`}>
            <Masonry videos={videos} onOpen={open} wide={wide} gap="gap-1.5" />
            {page < pages && (
              <button onClick={() => void load(page + 1)} disabled={loading}
                className="mx-auto mt-4 mb-6 h-10 px-8 rounded-(--r-ctl) bg-s2 text-[12.5px] text-on pressable disabled:opacity-50 flex items-center gap-1">
                {loading ? "加载中…" : "加载更多"}<IChevR size={13} className="rotate-90" />
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
