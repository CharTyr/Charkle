/**
 * Charkle Extension — Passive Main-World Multi-Platform Media Feed Observer (read-only)
 *
 * Passively reads JSON responses that X, Bluesky, Threads, Instagram, and Douyin web apps already fetch
 * so multi-image posts, carousels, and MP4 videos are captured losslessly at full resolution
 * without issuing extra private API calls or depending on rotating query signatures.
 */
(() => {
  if (window.__charkleSocialPageBridgeInstalled) return;
  window.__charkleSocialPageBridgeInstalled = true;
  window.__charkleXPageBridgeInstalled = true;

  const ORIGIN = window.location.origin;
  const HOST = window.location.hostname.toLowerCase();

  const PLATFORM =
    HOST === 'x.com' ||
    HOST === 'www.x.com' ||
    HOST === 'mobile.x.com' ||
    HOST === 'twitter.com' ||
    HOST === 'www.twitter.com' ||
    HOST === 'mobile.twitter.com'
      ? 'x'
      : HOST === 'bsky.app' || HOST === 'www.bsky.app'
        ? 'bluesky'
        : HOST === 'threads.net' ||
            HOST === 'www.threads.net' ||
            HOST === 'threads.com' ||
            HOST === 'www.threads.com'
          ? 'threads'
          : HOST === 'instagram.com' || HOST === 'www.instagram.com' || HOST === 'm.instagram.com'
            ? 'instagram'
            : HOST === 'douyin.com' || HOST === 'www.douyin.com' || HOST === 'm.douyin.com'
              ? 'douyin'
              : null;

  if (!PLATFORM) return;

  function isTargetEndpoint(rawUrl) {
    if (typeof rawUrl !== 'string' || !rawUrl) return false;
    if (PLATFORM === 'x') {
      return (
        rawUrl.includes('/i/api/graphql/') &&
        /(?:UserMedia|UserTweets|UserTweetsAndReplies|UserHighlightsTweets|TweetDetail|Bookmarks|Likes)\b/.test(
          rawUrl,
        )
      );
    }
    if (PLATFORM === 'bluesky') {
      return /(?:app\.bsky\.feed\.getAuthorFeed|app\.bsky\.feed\.getActorLikes|app\.bsky\.feed\.getPostThread)/.test(
        rawUrl,
      );
    }
    if (PLATFORM === 'threads') {
      return rawUrl.includes('/api/graphql') || rawUrl.includes('/graphql/query');
    }
    if (PLATFORM === 'instagram') {
      return (
        rawUrl.includes('/graphql/query') ||
        rawUrl.includes('/api/graphql') ||
        rawUrl.includes('/api/v1/feed/user/') ||
        rawUrl.includes('/api/v1/clips/user/') ||
        rawUrl.includes('/api/v1/feed/saved/') ||
        rawUrl.includes('/api/v1/users/web_profile_info')
      );
    }
    if (PLATFORM === 'douyin') {
      return /\/aweme\/v[12]\/web\/(?:aweme\/(?:listcollection|favorite|post|detail)|collects\/(?:list|video\/list))\b/.test(
        rawUrl,
      );
    }
    return false;
  }

  function upgradeHttps(rawUrl) {
    const trimmed = String(rawUrl || '').trim();
    if (!trimmed) return '';
    let candidate = trimmed;
    if (candidate.startsWith('//')) candidate = `https:${candidate}`;
    else if (/^http:\/\//i.test(candidate)) candidate = `https://${candidate.slice(7)}`;
    try {
      const u = new URL(candidate);
      if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
      return u.href;
    } catch {
      return '';
    }
  }

  function formatDate(raw) {
    if (raw === null || raw === undefined || raw === '') {
      return { publishedAtText: null, publishedDateKey: '' };
    }
    let d;
    if (typeof raw === 'number' && Number.isFinite(raw)) {
      d = new Date(raw > 10_000_000_000 ? raw : raw * 1000);
    } else {
      d = new Date(String(raw));
    }
    if (Number.isNaN(d.getTime())) return { publishedAtText: null, publishedDateKey: '' };
    const pad = (n) => String(n).padStart(2, '0');
    const y = d.getFullYear();
    const m = pad(d.getMonth() + 1);
    const day = pad(d.getDate());
    return {
      publishedAtText: `${y}-${m}-${day} ${pad(d.getHours())}:${pad(d.getMinutes())}`,
      publishedDateKey: `${y}-${m}-${day}`,
    };
  }

  // MARK: - X / Twitter Extractor

  function upgradeTwitterMediaUrl(rawUrl, preferredName) {
    const href = upgradeHttps(rawUrl);
    if (!href) return '';
    try {
      const u = new URL(href);
      u.hash = '';
      if (u.hostname.toLowerCase() === 'pbs.twimg.com' && u.pathname.startsWith('/media/')) {
        const colonIdx = u.pathname.indexOf(':');
        if (colonIdx > 0) u.pathname = u.pathname.slice(0, colonIdx);
        if (!u.searchParams.get('format')) {
          const extMatch = /\.([a-z0-9]+)$/i.exec(u.pathname);
          if (extMatch) {
            const ext = extMatch[1].toLowerCase() === 'jpeg' ? 'jpg' : extMatch[1].toLowerCase();
            if (ext === 'jpg' || ext === 'png' || ext === 'webp') {
              u.pathname = u.pathname.slice(0, -extMatch[0].length);
              u.searchParams.set('format', ext);
            }
          }
        }
        u.searchParams.set('name', preferredName || 'orig');
      }
      return u.href;
    } catch {
      return '';
    }
  }

  function pickBestMp4(videoInfo) {
    const variants = Array.isArray(videoInfo?.variants) ? videoInfo.variants : [];
    let bestUrl = '';
    let bestBitrate = -1;
    for (const v of variants) {
      const url = String(v?.url || '').trim();
      if (!url || !/^https?:\/\//i.test(url)) continue;
      const ct = String(v?.content_type || '').toLowerCase();
      if (ct !== 'video/mp4' && !/\.mp4(?:$|\?)/i.test(url)) continue;
      const bitrate = Number(v?.bitrate ?? 0);
      if (!bestUrl || bitrate >= bestBitrate) {
        bestUrl = url;
        bestBitrate = Number.isFinite(bitrate) ? bitrate : 0;
      }
    }
    return bestUrl || null;
  }

  function unwrapTweet(node) {
    if (!node || typeof node !== 'object') return null;
    if (node.__typename === 'TweetWithVisibilityResults' && node.tweet) return node.tweet;
    if (node.tweet && typeof node.tweet === 'object' && node.tweet.legacy) return node.tweet;
    if (node.legacy && (node.rest_id || node.legacy.id_str)) return node;
    return null;
  }

  function readXUser(tweetObj) {
    const ur = tweetObj?.core?.user_results?.result;
    const uc = ur?.core || {};
    const ul = ur?.legacy || {};
    const handle = String(uc.screen_name || ul.screen_name || '').trim().replace(/^@/, '');
    const name = String(uc.name || ul.name || handle || '').trim();
    let avatar = String(ur?.avatar?.image_url || ul.profile_image_url_https || '').trim();
    if (avatar && avatar.includes('_normal.')) avatar = avatar.replace('_normal.', '_400x400.');
    return { authorHandle: handle, authorName: name || handle, authorAvatarURL: avatar || null };
  }

  function readXMedia(legacy) {
    const rawList =
      Array.isArray(legacy?.extended_entities?.media) && legacy.extended_entities.media.length > 0
        ? legacy.extended_entities.media
        : Array.isArray(legacy?.entities?.media)
          ? legacy.entities.media
          : [];
    const out = [];
    const seen = new Set();
    for (const m of rawList) {
      if (!m || typeof m !== 'object') continue;
      const t = String(m.type || 'photo').toLowerCase();
      const thumbRaw = m.media_url_https || m.media_url || '';
      const thumbUrl = upgradeTwitterMediaUrl(thumbRaw, 'large') || thumbRaw;
      const width = Number(m.original_info?.width || m.sizes?.large?.w || 0) || 0;
      const height = Number(m.original_info?.height || m.sizes?.large?.h || 0) || 0;
      if (t === 'video' || t === 'animated_gif') {
        const mp4 = pickBestMp4(m.video_info);
        const url = mp4 || thumbUrl;
        if (!url || seen.has(url)) continue;
        seen.add(url);
        out.push({ kind: t === 'animated_gif' ? 'gif' : 'video', url, thumbnailURL: thumbUrl || null, width, height });
      } else {
        const orig = upgradeTwitterMediaUrl(thumbRaw, 'orig');
        if (!orig || seen.has(orig)) continue;
        seen.add(orig);
        out.push({ kind: 'photo', url: orig, thumbnailURL: thumbUrl || orig, width, height });
      }
    }
    return out;
  }

  function extractXTweets(payload) {
    const byId = new Map();
    if (!payload || typeof payload !== 'object') return [];
    const stack = [payload];
    const visited = new Set();
    while (stack.length > 0) {
      const cur = stack.pop();
      if (!cur || typeof cur !== 'object' || visited.has(cur)) continue;
      visited.add(cur);
      if (Array.isArray(cur)) {
        for (let i = cur.length - 1; i >= 0; i -= 1) {
          if (cur[i] && typeof cur[i] === 'object') stack.push(cur[i]);
        }
        continue;
      }
      const candidate = cur.tweet_results?.result ? unwrapTweet(cur.tweet_results.result) : null;
      if (candidate && candidate.legacy) {
        const outerUser = readXUser(candidate);
        const rtInner = unwrapTweet(candidate.legacy?.retweeted_status_result?.result);
        const isRetweet = Boolean(rtInner);
        const target = rtInner || candidate;
        const legacy = target.legacy || {};
        const tweetID = String(target.rest_id || legacy.id_str || '').trim();
        const media = readXMedia(legacy);
        if (/^\d{1,24}$/.test(tweetID) && media.length > 0) {
          const user = readXUser(target);
          const authorHandle = user.authorHandle || outerUser.authorHandle || 'i';
          const noteText = target.note_tweet?.note_tweet_results?.result?.text || '';
          const bodyText = String(noteText || legacy.full_text || legacy.text || '').trim();
          const dates = formatDate(legacy.created_at);
          const rec = {
            platform: 'x',
            postID: tweetID,
            tweetID,
            originalURL: `https://x.com/${authorHandle}/status/${tweetID}`,
            dedupKey: `x:${tweetID}`,
            authorName: user.authorName || authorHandle,
            authorHandle,
            authorAvatarURL: user.authorAvatarURL,
            publishedAtText: dates.publishedAtText,
            publishedDateKey: dates.publishedDateKey,
            title: '',
            bodyText,
            isRetweet,
            retweetedByHandle: isRetweet ? outerUser.authorHandle || null : null,
            media,
            hasVideo: media.some((m) => m.kind === 'video' || m.kind === 'gif'),
            needsEnrich: false,
          };
          const prev = byId.get(tweetID);
          if (!prev || rec.media.length > prev.media.length) byId.set(tweetID, rec);
        }
        continue;
      }
      for (const k of Object.keys(cur)) {
        if (k === 'quoted_status_result') continue;
        const v = cur[k];
        if (v && typeof v === 'object') stack.push(v);
      }
    }
    return Array.from(byId.values());
  }

  // MARK: - Bluesky Extractor

  function extractBlueskyPosts(payload) {
    const feed = Array.isArray(payload?.feed) ? payload.feed : [];
    const byKey = new Map();
    for (const entry of feed) {
      const post = entry?.post;
      if (!post || typeof post !== 'object') continue;
      const m = /\/app\.bsky\.feed\.post\/([a-zA-Z0-9._-]+)$/.exec(String(post.uri || ''));
      const postID = m ? m[1] : '';
      if (!postID) continue;
      const authorHandle = String(post.author?.handle || post.author?.did || '').trim().replace(/^@/, '');
      const authorName = String(post.author?.displayName || authorHandle || 'Bluesky').trim();
      const isRetweet = Boolean(entry?.reason && String(entry.reason.$type || '').toLowerCase().includes('repost'));
      const embed = post.embed || {};
      const media = [];
      const seen = new Set();
      for (const list of [embed.images, embed.media?.images]) {
        if (!Array.isArray(list)) continue;
        for (const img of list) {
          const full = upgradeHttps(img?.fullsize || img?.thumb || '');
          const thumb = upgradeHttps(img?.thumb || full);
          if (!full || seen.has(full)) continue;
          seen.add(full);
          media.push({ kind: 'photo', url: full, thumbnailURL: thumb || full });
        }
      }
      const videoNode =
        String(embed.$type || '').includes('video')
          ? embed
          : String(embed.media?.$type || '').includes('video')
            ? embed.media
            : null;
      if (videoNode) {
        const url = upgradeHttps(videoNode.playlist || videoNode.thumbnail || '');
        const thumb = upgradeHttps(videoNode.thumbnail || '');
        if (url && !seen.has(url)) {
          seen.add(url);
          media.push({ kind: 'video', url, thumbnailURL: thumb || null });
        }
      }
      if (media.length === 0) continue;
      const dates = formatDate(post.record?.createdAt || post.indexedAt);
      const dedupKey = `bsky:${authorHandle.toLowerCase()}:${postID}`;
      byKey.set(dedupKey, {
        platform: 'bluesky',
        postID,
        tweetID: postID,
        originalURL: `https://bsky.app/profile/${authorHandle}/post/${postID}`,
        dedupKey,
        authorName,
        authorHandle,
        authorAvatarURL: upgradeHttps(post.author?.avatar || '') || null,
        publishedAtText: dates.publishedAtText,
        publishedDateKey: dates.publishedDateKey,
        title: '',
        bodyText: String(post.record?.text || '').trim(),
        isRetweet,
        media,
        hasVideo: media.some((x) => x.kind === 'video' || x.kind === 'gif'),
        needsEnrich: false,
        referer: 'https://bsky.app/',
      });
    }
    return Array.from(byKey.values());
  }

  // MARK: - Threads & Instagram Shared Meta Media Extractor

  function pickBestMetaCandidate(list) {
    if (!Array.isArray(list) || list.length === 0) return null;
    let best = null;
    let bestArea = -1;
    for (const c of list) {
      const url = upgradeHttps(c?.url || '');
      if (!url) continue;
      const w = Number(c?.width || 0) || 0;
      const h = Number(c?.height || 0) || 0;
      const area = w * h;
      if (!best || area > bestArea) {
        best = { url, width: w, height: h };
        bestArea = area;
      }
    }
    return best;
  }

  function readMetaMediaItem(node) {
    if (!node || typeof node !== 'object') return null;
    const bestImg = pickBestMetaCandidate(node.image_versions2?.candidates);
    const imgUrl = upgradeHttps(node.display_url || '') || bestImg?.url || '';
    const bestVid = pickBestMetaCandidate(node.video_versions);
    const vidUrl = upgradeHttps(node.video_url || '') || bestVid?.url || '';
    if (vidUrl) {
      return {
        kind: 'video',
        url: vidUrl,
        thumbnailURL: imgUrl || null,
        width: bestVid?.width || bestImg?.width || 0,
        height: bestVid?.height || bestImg?.height || 0,
      };
    }
    if (imgUrl) {
      return {
        kind: 'photo',
        url: imgUrl,
        thumbnailURL: imgUrl,
        width: bestImg?.width || 0,
        height: bestImg?.height || 0,
      };
    }
    return null;
  }

  function readMetaMediaList(node) {
    const out = [];
    const seen = new Set();
    const add = (item) => {
      if (!item || !item.url || seen.has(item.url)) return;
      seen.add(item.url);
      out.push(item);
    };
    if (Array.isArray(node.carousel_media) && node.carousel_media.length > 0) {
      for (const slide of node.carousel_media) add(readMetaMediaItem(slide));
    } else if (Array.isArray(node.edge_sidecar_to_children?.edges) && node.edge_sidecar_to_children.edges.length > 0) {
      for (const edge of node.edge_sidecar_to_children.edges) add(readMetaMediaItem(edge?.node));
    } else {
      add(readMetaMediaItem(node));
    }
    return out;
  }

  function extractThreadsOrInstagramPosts(payload, platform) {
    const byCode = new Map();
    if (!payload || typeof payload !== 'object') return [];
    const stack = [payload];
    const visited = new Set();
    while (stack.length > 0) {
      const cur = stack.pop();
      if (!cur || typeof cur !== 'object' || visited.has(cur)) continue;
      visited.add(cur);
      if (Array.isArray(cur)) {
        for (let i = cur.length - 1; i >= 0; i -= 1) {
          if (cur[i] && typeof cur[i] === 'object') stack.push(cur[i]);
        }
        continue;
      }
      const code = String(cur.code || cur.shortcode || '').trim();
      const hasCarrier = Boolean(
        cur.carousel_media ||
          cur.image_versions2 ||
          cur.video_versions ||
          cur.display_url ||
          cur.edge_sidecar_to_children,
      );
      if (code && /^[a-zA-Z0-9_-]{4,40}$/.test(code) && hasCarrier && (cur.user || cur.owner || platform === 'instagram')) {
        const media = readMetaMediaList(cur);
        if (media.length > 0) {
          const u = cur.user || cur.owner || {};
          const handle = String(u.username || platform).trim().replace(/^@/, '');
          const authorName = String(u.full_name || handle).trim();
          const bodyText = String(
            cur.caption?.text || cur.edge_media_to_caption?.edges?.[0]?.node?.text || '',
          ).trim();
          const dates = formatDate(cur.taken_at ?? cur.taken_at_timestamp);
          const isRepost = Boolean(cur.text_post_app_info?.share_info?.reposted_post || cur.is_repost);
          const isReel =
            platform === 'instagram' &&
            (cur.product_type === 'clips' ||
              cur.__typename === 'GraphVideo' ||
              (media.length === 1 && media[0].kind === 'video'));
          const originalURL =
            platform === 'threads'
              ? `https://www.threads.net/@${handle}/post/${code}`
              : `https://www.instagram.com/${isReel ? 'reel' : 'p'}/${code}/`;
          const dedupKey = platform === 'threads' ? `threads:${code}` : `ig:${code}`;
          const rec = {
            platform,
            postID: code,
            tweetID: code,
            originalURL,
            dedupKey,
            authorName,
            authorHandle: handle,
            authorAvatarURL: upgradeHttps(u.profile_pic_url || '') || null,
            publishedAtText: dates.publishedAtText,
            publishedDateKey: dates.publishedDateKey,
            title: '',
            bodyText,
            isRetweet: isRepost,
            media,
            hasVideo: media.some((m) => m.kind === 'video' || m.kind === 'gif'),
            needsEnrich: false,
            referer: platform === 'threads' ? 'https://www.threads.net/' : 'https://www.instagram.com/',
          };
          const prev = byCode.get(code);
          if (!prev || rec.media.length > prev.media.length) byCode.set(code, rec);
        }
        continue;
      }
      for (const k of Object.keys(cur)) {
        if (k === 'quoted_post' || k === 'reposted_post') continue;
        const v = cur[k];
        if (v && typeof v === 'object') stack.push(v);
      }
    }
    return Array.from(byCode.values());
  }

  // MARK: - Douyin Passive Web API Extractor

  function isHeicDouyinUrl(rawUrl) {
    const lower = String(rawUrl || '').toLowerCase();
    return (
      lower.includes('.heic') ||
      lower.includes('.heif') ||
      (lower.includes('~tplv-') && lower.includes('heic')) ||
      lower.includes('format=heic') ||
      lower.includes('format=heif')
    );
  }

  function pickBestDouyinImg(urlList) {
    if (!Array.isArray(urlList) || urlList.length === 0) return '';
    const cleaned = [];
    const seen = new Set();
    for (const raw of urlList) {
      const href = upgradeHttps(raw);
      if (!href || seen.has(href)) continue;
      seen.add(href);
      cleaned.push(href);
    }
    if (cleaned.length === 0) return '';
    return cleaned.find((u) => !isHeicDouyinUrl(u)) || cleaned[0];
  }

  function pickCleanDouyinVideoFromList(urlList) {
    if (!Array.isArray(urlList) || urlList.length === 0) return '';
    const valid = [];
    const seen = new Set();
    for (const raw of urlList) {
      const href = upgradeHttps(raw);
      if (!href || seen.has(href)) continue;
      seen.add(href);
      valid.push(href);
    }
    if (valid.length === 0) return '';
    const clean = valid.find((u) => {
      const low = u.toLowerCase();
      return !low.includes('/playwm/') && !low.includes('watermark=1') && !/\/aweme\/v1\/playwm/i.test(u);
    });
    return clean || valid[0].replace(/\/playwm\//gi, '/play/');
  }

  function pickBestDouyinVideo(videoObj) {
    if (!videoObj || typeof videoObj !== 'object') return null;
    const bitRates = Array.isArray(videoObj.bit_rate) ? videoObj.bit_rate : [];
    const ranked = [];
    for (const br of bitRates) {
      if (!br || typeof br !== 'object') continue;
      const url = pickCleanDouyinVideoFromList(br.play_addr?.url_list);
      if (!url) continue;
      const isH265 = Number(br.is_h265 || 0) === 1 || /265|hevc/i.test(String(br.gear_name || ''));
      const bitrateNum = Number(br.bit_rate || br.play_addr?.data_size || 0) || 0;
      const width = Number(br.play_addr?.width || 0) || 0;
      const height = Number(br.play_addr?.height || 0) || 0;
      ranked.push({ url, isH265, bitrateNum, width, height });
    }
    if (ranked.length > 0) {
      ranked.sort((a, b) => {
        if (a.isH265 !== b.isH265) return a.isH265 ? 1 : -1;
        const areaDiff = b.width * b.height - a.width * a.height;
        if (areaDiff !== 0) return areaDiff;
        return b.bitrateNum - a.bitrateNum;
      });
      return ranked[0].url;
    }
    return (
      pickCleanDouyinVideoFromList(videoObj.play_addr_h264?.url_list) ||
      pickCleanDouyinVideoFromList(videoObj.play_addr?.url_list) ||
      pickCleanDouyinVideoFromList(videoObj.play_addr_lowbr?.url_list) ||
      null
    );
  }

  function parseDouyinMetric(raw) {
    if (typeof raw === 'number' && Number.isFinite(raw)) {
      return raw >= 0 ? Math.round(raw) : null;
    }
    const text = String(raw ?? '').trim().replace(/[,+]/g, '');
    if (!text) return null;
    const yi = /^(\d+(?:\.\d+)?)\s*亿$/i.exec(text);
    if (yi) return Math.round(Number.parseFloat(yi[1]) * 100_000_000);
    const wan = /^(\d+(?:\.\d+)?)\s*[万w]$/i.exec(text);
    if (wan) return Math.round(Number.parseFloat(wan[1]) * 10_000);
    const qian = /^(\d+(?:\.\d+)?)\s*[千k]$/i.exec(text);
    if (qian) return Math.round(Number.parseFloat(qian[1]) * 1_000);
    if (/^\d+$/.test(text)) return Number.parseInt(text, 10);
    return null;
  }

  function parseDouyinEndpointMeta(rawUrl) {
    const out = { sourceEndpoint: '', collectionId: null };
    if (typeof rawUrl !== 'string' || !rawUrl) return out;
    if (/\/aweme\/v[12]\/web\/aweme\/listcollection\b/.test(rawUrl)) out.sourceEndpoint = 'listcollection';
    else if (/\/aweme\/v[12]\/web\/collects\/video\/list\b/.test(rawUrl)) out.sourceEndpoint = 'collects_video_list';
    else if (/\/aweme\/v[12]\/web\/collects\/list\b/.test(rawUrl)) out.sourceEndpoint = 'collects_list';
    else if (/\/aweme\/v[12]\/web\/aweme\/favorite\b/.test(rawUrl)) out.sourceEndpoint = 'favorite';
    else if (/\/aweme\/v[12]\/web\/aweme\/post\b/.test(rawUrl)) out.sourceEndpoint = 'post';
    else if (/\/aweme\/v[12]\/web\/aweme\/detail\b/.test(rawUrl)) out.sourceEndpoint = 'detail';
    try {
      const u = new URL(rawUrl, ORIGIN);
      const cid = (u.searchParams.get('collects_id') || u.searchParams.get('collection_id') || '').trim();
      if (cid) out.collectionId = cid;
    } catch {
      // ignore invalid URL
    }
    return out;
  }

  function extractDouyinCollections(payload) {
    if (!payload || typeof payload !== 'object') return [];
    const rawList = Array.isArray(payload.collects_list)
      ? payload.collects_list
      : Array.isArray(payload.data?.collects_list)
        ? payload.data.collects_list
        : Array.isArray(payload.favorite_folder_list)
          ? payload.favorite_folder_list
          : [];
    const byId = new Map();
    for (const item of rawList) {
      if (!item || typeof item !== 'object') continue;
      const id = String(item.collects_id_str || item.collects_id || item.id_str || item.id || '').trim();
      const name = String(item.collects_name || item.name || item.title || '').trim();
      if (!id || !name) continue;
      const totalCount = parseDouyinMetric(item.total_number ?? item.item_count ?? item.count);
      byId.set(id, { id, name, totalCount });
    }
    return Array.from(byId.values());
  }

  function extractDouyinPosts(payload, endpointMeta) {
    if (!payload || typeof payload !== 'object') return [];
    const candidates = [];
    const pushArr = (arr) => {
      if (!Array.isArray(arr)) return;
      for (const entry of arr) {
        if (!entry || typeof entry !== 'object') continue;
        if (entry.aweme_id || entry.awemeId) candidates.push(entry);
        else if (entry.aweme && typeof entry.aweme === 'object') candidates.push(entry.aweme);
        else if (entry.aweme_info && typeof entry.aweme_info === 'object') candidates.push(entry.aweme_info);
      }
    };
    pushArr(payload.aweme_list);
    pushArr(payload.aweme_details);
    pushArr(payload.item_list);
    pushArr(payload.cards);
    if (payload.aweme_detail && typeof payload.aweme_detail === 'object') candidates.push(payload.aweme_detail);
    if (payload.data && typeof payload.data === 'object') {
      pushArr(payload.data.aweme_list);
      pushArr(payload.data.aweme_details);
      pushArr(payload.data.item_list);
      if (payload.data.aweme_detail && typeof payload.data.aweme_detail === 'object') {
        candidates.push(payload.data.aweme_detail);
      }
    }

    const byId = new Map();
    for (const aweme of candidates) {
      const awemeId = String(aweme.aweme_id || aweme.awemeId || '').trim();
      if (!/^\d{15,22}$/.test(awemeId)) continue;

      const imagesArr = Array.isArray(aweme.images) ? aweme.images : [];
      const isPhotoNote = imagesArr.length > 0 || Number(aweme.aweme_type) === 68;
      const author = aweme.author && typeof aweme.author === 'object' ? aweme.author : {};
      const authorName = String(author.nickname || '抖音用户').trim() || '抖音用户';
      const rawUnique = String(author.unique_id || '').trim();
      const rawShort = String(author.short_id || '').trim();
      const authorHandle =
        rawUnique && rawUnique !== '0' && !rawUnique.startsWith('MS4wLjAB')
          ? rawUnique
          : rawShort && rawShort !== '0' && !rawShort.startsWith('MS4wLjAB')
            ? rawShort
            : '';
      const authorAvatarURL =
        pickBestDouyinImg(
          author.avatar_medium?.url_list ||
            author.avatar_thumb?.url_list ||
            author.avatar_larger?.url_list ||
            [],
        ) || null;

      const desc = String(aweme.desc || '').trim();
      const explicitTitle = String(aweme.item_title || aweme.preview_title || '').trim();
      const title = explicitTitle
        ? explicitTitle.slice(0, 120)
        : desc.replace(/#[^\s#]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80) || desc.slice(0, 80);

      const dates = formatDate(aweme.create_time);
      const stats = aweme.statistics && typeof aweme.statistics === 'object' ? aweme.statistics : {};
      const tags = [];
      const seenTags = new Set();
      const pushTag = (t) => {
        const clean = String(t || '').trim().replace(/^#/, '');
        if (!clean || clean.length > 32) return;
        const low = clean.toLowerCase();
        if (seenTags.has(low)) return;
        seenTags.add(low);
        tags.push(clean);
      };
      if (Array.isArray(aweme.text_extra)) {
        for (const te of aweme.text_extra) {
          if (te?.hashtag_name) pushTag(te.hashtag_name);
        }
      }
      for (const m of desc.matchAll(/#([^\s#@]{1,30})/g)) {
        if (m[1]) pushTag(m[1]);
      }

      const media = [];
      const seenUrls = new Set();
      let hasVideo = false;
      let videoURL = null;
      let durationSeconds = null;

      if (isPhotoNote && imagesArr.length > 0) {
        for (const imgObj of imagesArr) {
          if (!imgObj || typeof imgObj !== 'object') continue;
          const url =
            pickBestDouyinImg(imgObj.url_list) || pickBestDouyinImg(imgObj.download_url_list);
          if (!url || seenUrls.has(url)) continue;
          seenUrls.add(url);
          media.push({
            kind: 'photo',
            url,
            thumbnailURL: url,
            width: Number(imgObj.width || 0) || 0,
            height: Number(imgObj.height || 0) || 0,
          });
        }
      } else {
        const videoObj = aweme.video && typeof aweme.video === 'object' ? aweme.video : {};
        const coverUrl =
          pickBestDouyinImg(videoObj.origin_cover?.url_list) ||
          pickBestDouyinImg(videoObj.cover?.url_list) ||
          pickBestDouyinImg(videoObj.dynamic_cover?.url_list) ||
          '';
        videoURL = pickBestDouyinVideo(videoObj);
        const rawDur = Number(videoObj.duration ?? aweme.duration);
        if (Number.isFinite(rawDur) && rawDur > 0) {
          durationSeconds = Math.round((rawDur >= 1000 ? rawDur / 1000 : rawDur) * 10) / 10;
        }
        const width = Number(videoObj.width || videoObj.play_addr?.width || 0) || 0;
        const height = Number(videoObj.height || videoObj.play_addr?.height || 0) || 0;
        hasVideo = true;
        if (videoURL) {
          seenUrls.add(videoURL);
          media.push({ kind: 'video', url: videoURL, thumbnailURL: coverUrl || null, width, height });
        } else if (coverUrl) {
          seenUrls.add(coverUrl);
          media.push({ kind: 'photo', url: coverUrl, thumbnailURL: coverUrl, width, height });
        }
      }

      const originalURL = isPhotoNote
        ? `https://www.douyin.com/note/${awemeId}`
        : `https://www.douyin.com/video/${awemeId}`;

      const rec = {
        platform: 'douyin',
        postID: awemeId,
        tweetID: awemeId,
        videoID: awemeId,
        originalURL,
        dedupKey: `douyin:${awemeId}`,
        authorName,
        authorHandle,
        authorAvatarURL,
        publishedAtText: dates.publishedAtText,
        publishedDateKey: dates.publishedDateKey,
        title,
        articleTitle: title || null,
        bodyText: desc || title || originalURL,
        isRetweet: false,
        likeCount: parseDouyinMetric(stats.digg_count),
        replyCount: parseDouyinMetric(stats.comment_count),
        repostCount: parseDouyinMetric(stats.share_count),
        viewCount: parseDouyinMetric(stats.play_count),
        durationSeconds,
        videoDurationSeconds: durationSeconds,
        media,
        hasVideo,
        videoURL,
        needsEnrich: false,
        referer: 'https://www.douyin.com/',
        tags: tags.slice(0, 12),
        sourceEndpoint: endpointMeta?.sourceEndpoint || '',
        collectionId: endpointMeta?.collectionId || null,
      };
      const prev = byId.get(awemeId);
      const prevScore = prev ? (prev.media?.length || 0) * 10 + (prev.videoURL ? 2 : 0) : -1;
      const nextScore = (rec.media?.length || 0) * 10 + (rec.videoURL ? 2 : 0);
      if (!prev || nextScore >= prevScore) byId.set(awemeId, rec);
    }
    return Array.from(byId.values());
  }

  function parseJsonOrNdjson(text) {
    if (!text || typeof text !== 'string') return [];
    const trimmed = text.trim();
    if (!trimmed) return [];
    // Meta GraphQL sometimes returns multiple newline-delimited JSON chunks (`for (;;);{...}\n{...}`)
    const cleaned = trimmed.replace(/^for\s*\(\s*;\s*;\s*\)\s*;\s*/, '');
    try {
      return [JSON.parse(cleaned)];
    } catch {
      const results = [];
      for (const line of cleaned.split(/\r?\n/)) {
        const part = line.trim();
        if (!part || !part.startsWith('{')) continue;
        try {
          results.push(JSON.parse(part));
        } catch {
          // ignore malformed line
        }
      }
      return results;
    }
  }

  function emitFromPayloads(payloads, rawUrl = '') {
    try {
      const allPosts = [];
      const allCollections = [];
      const endpointMeta = PLATFORM === 'douyin' ? parseDouyinEndpointMeta(rawUrl) : null;
      for (const json of payloads) {
        if (!json || typeof json !== 'object') continue;
        if (PLATFORM === 'x') allPosts.push(...extractXTweets(json));
        else if (PLATFORM === 'bluesky') allPosts.push(...extractBlueskyPosts(json));
        else if (PLATFORM === 'threads' || PLATFORM === 'instagram') {
          allPosts.push(...extractThreadsOrInstagramPosts(json, PLATFORM));
        } else if (PLATFORM === 'douyin') {
          allCollections.push(...extractDouyinCollections(json));
          allPosts.push(...extractDouyinPosts(json, endpointMeta));
        }
      }
      if (PLATFORM === 'douyin' && allCollections.length > 0) {
        window.postMessage(
          {
            __charkleSocialBridge: true,
            __charkleXBridge: false,
            platform: 'douyin',
            type: 'DOUYIN_COLLECTIONS',
            collections: allCollections,
          },
          ORIGIN,
        );
      }
      if (allPosts.length > 0) {
        window.postMessage(
          {
            __charkleSocialBridge: true,
            __charkleXBridge: PLATFORM === 'x',
            platform: PLATFORM,
            type: 'GRAPHQL_POSTS',
            posts: allPosts,
            tweets: PLATFORM === 'x' ? allPosts : undefined,
            sourceEndpoint: endpointMeta?.sourceEndpoint || undefined,
            collectionId: endpointMeta?.collectionId || undefined,
          },
          ORIGIN,
        );
      }
    } catch {
      // never interfere with host page
    }
  }

  // Passive fetch observer
  if (typeof window.fetch === 'function') {
    const origFetch = window.fetch;
    window.fetch = function charkleWrappedFetch(input) {
      const url = typeof input === 'string' ? input : input?.url || '';
      const promise = origFetch.apply(this, arguments);
      if (isTargetEndpoint(url)) {
        promise
          .then((res) => {
            if (!res || !res.ok) return;
            res
              .clone()
              .text()
              .then((text) => emitFromPayloads(parseJsonOrNdjson(text), url))
              .catch(() => {});
          })
          .catch(() => {});
      }
      return promise;
    };
  }

  function parseDouyinBodyCollectionId(body) {
    try {
      if (!body) return null;
      if (typeof body === 'string') {
        const m = /(?:^|[&?])(?:collects_id|collection_id)=([^&]+)/i.exec(body);
        if (m && m[1]) return decodeURIComponent(m[1]).trim() || null;
      } else if (typeof URLSearchParams === 'function' && body instanceof URLSearchParams) {
        return (body.get('collects_id') || body.get('collection_id') || '').trim() || null;
      }
    } catch {
      // ignore unreadable body
    }
    return null;
  }

  // Passive XMLHttpRequest observer
  if (typeof XMLHttpRequest === 'function' && XMLHttpRequest.prototype) {
    const origOpen = XMLHttpRequest.prototype.open;
    const origSend = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function charkleWrappedOpen(_method, url) {
      this.__charkleUrl = typeof url === 'string' ? url : String(url || '');
      return origOpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function charkleWrappedSend(body) {
      if (isTargetEndpoint(this.__charkleUrl)) {
        let reqUrl = this.__charkleUrl;
        if (PLATFORM === 'douyin' && !/[?&](?:collects_id|collection_id)=/i.test(reqUrl)) {
          const bodyCid = parseDouyinBodyCollectionId(body);
          if (bodyCid) {
            reqUrl += `${reqUrl.includes('?') ? '&' : '?'}collects_id=${encodeURIComponent(bodyCid)}`;
          }
        }
        this.addEventListener(
          'load',
          () => {
            try {
              if (this.status < 200 || this.status >= 300) return;
              if (this.responseType === 'json' && this.response) {
                emitFromPayloads([this.response], reqUrl);
              } else if ((!this.responseType || this.responseType === 'text') && this.responseText) {
                emitFromPayloads(parseJsonOrNdjson(this.responseText), reqUrl);
              } else if (
                this.responseType === 'arraybuffer' &&
                this.response &&
                typeof TextDecoder === 'function'
              ) {
                const decoded = new TextDecoder('utf-8').decode(this.response);
                if (decoded) emitFromPayloads(parseJsonOrNdjson(decoded), reqUrl);
              } else if (
                this.responseType === 'blob' &&
                this.response &&
                typeof this.response.text === 'function'
              ) {
                this.response
                  .text()
                  .then((text) => emitFromPayloads(parseJsonOrNdjson(text), reqUrl))
                  .catch(() => {});
              }
            } catch {
              // ignore non-JSON payloads
            }
          },
          { passive: true },
        );
      }
      return origSend.apply(this, arguments);
    };
  }
})();
