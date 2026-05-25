local urlparse = require("socket.url")
local http = require("socket.http")
local cjson = require("cjson")
local utf8 = require("utf8")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))
local item_type = nil
local item_name = nil
local item_value = nil

local url_count = 0
local tries = 0
local downloaded = {}
local seen_200 = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local discovered_items = {}
local bad_items = {}
local ids = {}

local retry_url = false
local is_initial_url = true
local context = {}

local item_patterns = {
  ["^https?://tv%.kakao%.com/v/([0-9]+)$"]="video",
  ["^https?://tv%.kakao%.com/api/v1/ft/playlists/([0-9]+)$"]="playlist",
  ["^https?://tv%.kakao%.com/channel/([0-9]+)/info$"]="channel",
  ["^https?://(tv%.kakao%.com/player/script/sdk/.+)$"]="asset",
  ["^https?://(t1%.kakaocdn%.net/kakaotv/.+)$"]="asset",
  ["^https?://(t1%.kakaocdn%.net/thumb/.+)$"]="asset",
  ["^https?://(t1%.kakaocdn%.net/tvpot/thumb/.+)$"]="asset",
  ["^https?://(t1%.daumcdn%.net/news/.+)$"]="asset",
  ["^https?://(t1%.daumcdn%.net/tvpot/thumb/.+)$"]="asset",
  ["^https?://(t1%.kakaocdn%.net/play/.+)$"]="asset",
  ["^https?://(img1%.daumcdn%.net/thumb/.+)$"]="asset",
  ["^https?://(img1%.daumcdn%.net/kakaotv/[^/]+%.[0-9a-zA-Z]+.*)$"]="asset",
  ["^https?://(img1%.daumcdn%.net/kakaotv/.+/.+)$"]="asset",
  ["^https?://(img1%.kakaocdn%.net/kakaotv/.+)$"]="asset",
  ["^https?://(img1%.kakaocdn%.net/thumb/.+)$"]="asset",
  ["^https?://(mk%.kakaocdn%.net/dn/emoticon/.+)$"]="asset",
  ["^https?://(thumb%.kakaocdn%.net/dna/kamp/source/.+)$"]="asset"
}

local skipped_channel_ids = {
  ["1404"]=true,
  ["1492"]=true,
  ["1506"]=true,
  ["1588"]=true,
  ["1614"]=true,
  ["2856"]=true,
  ["4716"]=true,
  ["1938380"]=true,
  ["2370398"]=true,
  ["2370406"]=true,
  ["2370407"]=true,
  ["2370408"]=true,
  ["2370409"]=true,
  ["2370416"]=true,
  ["2370417"]=true,
  ["2370425"]=true,
  ["2370436"]=true,
  ["2370437"]=true,
  ["2372790"]=true,
  ["2630399"]=true,
  ["2735998"]=true,
  ["2935620"]=true,
  ["3358089"]=true,
  ["4163724"]=true,
  ["4177202"]=true,
  ["5569846"]=true,
  ["9124404"]=true,
  ["9605079"]=true
}

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  io.stdout:flush()
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file, "rb"))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if item ~= item_name and not target[item] then
    target[item] = true
    return true
  end
  return false
end

find_item = function(url)
  for pattern, name in pairs(item_patterns) do
    local value = string.match(url, pattern)
    if value then
      return {
        ["value"]=value,
        ["type"]=name
      }
    end
  end
end

found_video = function()
  if item_type == "video"
    and not abortgrab
    and not context["skipped_channel"]
    and not context["video_queued"] then
    error("No main video stream URL queued.")
  end
end

set_item = function(url)
  if ids[string.lower(url)] then
    return nil
  end
  local found = find_item(url)
  if found then
    local new_item_type = found["type"]
    local new_item_value = found["value"]
    local new_item_name = new_item_type .. ":" .. new_item_value
    if new_item_name ~= item_name then
      if item_name then
        found_video()
      end
      ids = {}
      context = {
        ["video_ids"]={}
      }
      item_value = new_item_value
      item_type = new_item_type
      ids[string.lower(item_value)] = true
      ids[string.lower(url)] = true
      abortgrab = false
      tries = 0
      retry_url = false
      is_initial_url = true
      item_name = new_item_name
      print("Archiving item " .. item_name)
    end
  end
end

allowed = function(url, parenturl)
  if ids[string.lower(url)] then
    return true
  end

  if (
    item_type == "channel"
    and (
      string.match(url, "^https?://tv%.kakao%.com/channel/[0-9]+/cliplink/")
      or string.match(url, "^https?://tv%.kakao%.com/channel/[0-9]+/playlist/[0-9]+")
    )
  ) or (
    item_type == "playlist"
    and (
      string.match(url, "^https?://tv%.kakao%.com/channel/[0-9]+/playlist/" .. item_value .. "$")
      or (
        string.match(url, "^https?://tv%.kakao%.com/channel/[0-9]+/cliplink/[^?]+%?")
        and string.match(url, "[?&]playlistId=" .. item_value .. "([&#]?)")
      )
    )
  ) or (
    item_type == "video"
    and (
      (
        string.match(url, "/readyNplay%?")
        and string.match(string.lower(url), "playlistid%%3d")
      )
      or string.match(url, "/related/cliplinks")
      or string.match(url, "^https?://tv%.kakao%.com/vapi/videos/v3/cliplink/")
      or string.match(url, "^https?://tv%.kakao%.com/vapi/v3/videos/.+/recommend%?")
    )
  ) then
    return false
  end

  local found = find_item(url)
  if found
    and (
      found["type"] ~= item_type
      or found["value"] ~= item_value
    ) then
    if found["type"] == "asset" then
      discover_item(discovered_items, "asset:" .. found["value"])
    end
    return false
  end

  if item_type == "video" then
    local found_video_id = string.match(url, "^https?://tv%.kakao%.com/v/([^/?#]+)")
      or string.match(url, "^https?://tv%.kakao%.com/channel/[0-9]+/cliplink/([^/?#]+)$")
      or string.match(url, "^https?://tv%.kakao%.com/embed/player/cliplink/([^/?#]+)")
      or string.match(url, "^https?://play%-tv%.kakao%.com/embed/player/cliplink/([^/?#]+)")
      or string.match(url, "^https?://play%-tv%.kakao%.com/katz/v1/close/cliplink/([^/]+)/info")
      or string.match(url, "^https?://play%-tv%.kakao%.com/katz/v4/ft/cliplink/([^/]+)/readyNplay%?")
      or string.match(url, "^https?://play%-tv%.kakao%.com/api/v1/ft/cliplinks/([^/?#]+)%?")
      or string.match(url, "^https?://play%-tv%.kakao%.com/api/v3/ft/cliplinks/([^/]+)/startAfter%?")
    if found_video_id then
      found_video_id = urlparse.unescape(found_video_id)
      if context["video_ids"][found_video_id]
        or context["video_ids"][string.gsub(found_video_id, "@my$", "")] then
        return true
      end
    end
  end

  if context["kamp_id"] then
    if (
      string.match(url, "^https?://kamp%.kakao%.com/vod/v1/src/")
      or string.match(url, "^https?://vst%.play%.kakao%.com/")
      or string.match(url, "^https?://vscf%.play%.kakao%.com/")
      or string.match(url, "^https?://thumb%.kakaocdn%.net/dna/kamp/source/")
      or string.match(url, "^https?://t1%.kakaocdn%.net/tvpot/thumb/")
      or string.match(url, "^https?://t1%.daumcdn%.net/tvpot/thumb/")
    )
    and string.match(url, string.gsub(context["kamp_id"], "([^0-9A-Za-z])", "%%%1")) then
      return true
    end
  end

  for _, pattern in pairs({
    "([0-9]+)",
    "([0-9a-zA-Z_%-%%%.%$@]+)"
  }) do
    for s in string.gmatch(url, pattern) do
      s = urlparse.unescape(s)
      if ids[string.lower(s)] then
        return true
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function (s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local json = nil

  downloaded[url] = true
  set_item(url)

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl, headers, body_data, method)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://") then
      return nil
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "[%s\\]") then
      return nil
    end
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0
      or string.len(newurl) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = url
    while string.match(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    local key = (method or "GET") .. "\0" .. url_ .. "\0" .. tostring(body_data)
    if not processed(key)
      and (body_data or not processed(url_))
      and allowed(url_, origurl) then
      local url_data = {
        url=url_,
        headers=headers or {}
      }
      if body_data then
        url_data["body_data"] = body_data
        url_data["method"] = method or "POST"
      end
      table.insert(urls, url_data)
      addedtolist[key] = true
      if not body_data then
        addedtolist[url_] = true
        addedtolist[url] = true
      end
      return true
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function check_manifest_url(newurl)
    local query = string.match(url, "%?(.+)$")
    if query
      and not string.match(newurl, "%?")
      and (
        string.match(url, "^https?://vst%.play%.kakao%.com/")
        or string.match(url, "^https?://vscf%.play%.kakao%.com/")
      ) then
      newurl = newurl .. "?" .. query
    end
    check(urlparse.absolute(url, newurl))
  end

  local function ready_nplay_url(referer, cliplink_id, service, section, profile)
    referer = referer or "https://tv.kakao.com/v/" .. item_value
    cliplink_id = cliplink_id or item_value
    service = service or "kakao_tv"
    section = section or "channel"
    profile = profile or "HIGH"
    local host = "https://tv.kakao.com"
    if service == "daum_tistory" then
      host = "https://play-tv.kakao.com"
    end
    return host .. "/katz/v4/ft/cliplink/" .. cliplink_id
      .. "/readyNplay?player=monet_html5"
      .. "&referer=" .. urlparse.escape(referer)
      .. "&pageReferer=&uuid=&profile=" .. profile
      .. "&service=" .. service .. "&section=" .. section
      .. "&fields=seekUrl,abrVideoLocationList&playerVersion=3.48.0&appVersion=148.0"
      .. "&startPosition=0&tid=&dteType=PC&continuousPlay=false&autoPlay=false"
      .. "&contentType=&drmType=widevine&ab=&literalList="
  end

  local function init_video_urls()
    context["init"] = true
    if not context["channel_clip_404"] then
      check("https://tv.kakao.com/api/v1/ft/cliplinks/" .. item_value)
    end
    check("https://tv.kakao.com/api/v1/ft/playmeta/cliplink/" .. item_value .. "?fields=@html5vod&service=kakao_tv&type=VOD")
    check("https://play-tv.kakao.com/api/v1/ft/playmeta/cliplink/" .. item_value .. "?fields=@html5vod&service=und_player&type=VOD")
    check("https://play-tv.kakao.com/api/v1/ft/cliplinks/" .. item_value .. "?fields=-*,clip,status")
    check("https://tv.kakao.com/api/v1/ft/cliplinks/" .. item_value .. "?fields=-*,clip,status")
    check("https://play-tv.kakao.com/embed/player/cliplink/" .. item_value)
    check("https://play-tv.kakao.com/katz/v1/close/cliplink/" .. item_value .. "/info")
    check(ready_nplay_url("https://tv.kakao.com/v/" .. item_value))
    check(
      "https://play-tv.kakao.com/katz/v4/ft/cliplink/" .. item_value
      .. "/readyNplay?player=monet_html5&referer=&pageReferer=&uuid="
      .. "&profile=HIGH&service=und_player&section=und_player"
      .. "&fields=seekUrl,abrVideoLocationList&playerVersion=3.48.0"
      .. "&appVersion=136.0.7103.25&startPosition=0&tid=&dteType=PC"
      .. "&continuousPlay=false&autoPlay=false&contentType="
      .. "&drmType=widevine&ab=&literalList="
    )
    check("https://tv.kakao.com/api/v1/ft/cliplinks/" .. item_value .. "/playlistclips")
    check("https://tv.kakao.com/api/v3/ft/cliplinks/" .. item_value .. "/startAfter?service=kakao_tv")
    check("https://play-tv.kakao.com/api/v3/ft/cliplinks/" .. item_value .. "/startAfter?service=und_player")
  end

  local function scan_json_urls(data, temp_only)
    if type(data) == "table" then
      for _, value in pairs(data) do
        scan_json_urls(value, temp_only)
      end
    elseif type(data) == "string" then
      if temp_only then
        if string.match(data, "^https?://thumb%.kakaocdn%.net/dna/kamp/source/") then
          ids[string.lower(data)] = true
          check(data)
        end
      else
        check(data)
      end
    end
  end

  local function check_thumbnails(thumbnail, sizes, c180)
    for _, source in ipairs({
      thumbnail,
      string.match(thumbnail, "^([^?]+)%?")
    }) do
      local thumb_urls = {source}
      for _, thumb in ipairs({
        {sizes, "https://t1.kakaocdn.net/thumb/C640x360.q50.fjpg/?fname="},
        {sizes, "https://t1.kakaocdn.net/thumb/C600x320.q50.fjpg/?fname="},
        {sizes, "https://img1.kakaocdn.net/thumb/C320x180.fjpg.q75/?fname="},
        {c180, "https://t1.kakaocdn.net/thumb/C180x100/?fname="}
      }) do
        if thumb[1] then
          table.insert(thumb_urls, thumb[2] .. urlparse.escape(source))
        end
      end
      for _, thumb_url in ipairs(thumb_urls) do
        ids[string.lower(thumb_url)] = true
        check(thumb_url)
      end
    end
  end

  local function check_clip_thumbnails(clip)
    if clip["thumbnailUrl"]
      and clip["thumbnailUrl"] ~= cjson.null then
      check_thumbnails(clip["thumbnailUrl"], true, false)
    end
    if clip["clipChapterThumbnailList"]
      and clip["clipChapterThumbnailList"] ~= cjson.null then
      for _, chapter in ipairs(clip["clipChapterThumbnailList"]) do
        if chapter["thumbnailUrl"]
          and chapter["thumbnailUrl"] ~= cjson.null then
          check_thumbnails(chapter["thumbnailUrl"], false, true)
        end
      end
    end
  end

  local function check_video_id(video_id)
    if video_id ~= item_value
      and not context["video_ids"][video_id] then
      context["video_ids"][video_id] = true
      print("Found alternative video id " .. video_id .. ".")
      check("https://tv.kakao.com/v/" .. video_id)
      if context["init"]
        and not string.match(video_id, "^[0-9]+$") then
        check("https://play-tv.kakao.com/embed/player/cliplink/" .. video_id)
        if not string.match(video_id, "@my$") then
          check("https://play-tv.kakao.com/embed/player/cliplink/" .. video_id .. "@my")
          check("https://tv.kakao.com/v/" .. video_id .. "@my")
        end
      end
      if context["channel_id"] then
        check("https://tv.kakao.com/channel/" .. context["channel_id"] .. "/cliplink/" .. video_id)
      end
    end
    video_id = string.gsub(video_id, "@my$", "")
    if context["tistory"]
      and not string.match(video_id, "^[0-9]+$") then
      for _, embed_url in ipairs({
        "https://play-tv.kakao.com/embed/player/cliplink/" .. video_id .. "@my?service=daum_tistory",
        "https://play-tv.kakao.com/embed/player/cliplink/" .. string.gsub(video_id, "%$", "%%24") .. "@my?service=daum_tistory"
      }) do
        check(embed_url)
      end
      check("https://play-tv.kakao.com/katz/v1/close/cliplink/" .. video_id .. "@my/info")
      check("https://play-tv.kakao.com/api/v1/ft/cliplinks/" .. video_id .. "@my?fields=-*,clip,status")
      for _, profile in ipairs({"HIGH", "MAIN"}) do
        check(ready_nplay_url(
          context["tistory_referer"],
          video_id .. "@my",
          "daum_tistory",
          "daum_tistory",
          profile
        ))
      end
    end
  end

  local function check_tistory_source(clip, channel)
    for _, text in pairs({
      clip["sourceUrl"],
      clip["description"],
      clip["service"] and clip["service"] ~= cjson.null and clip["service"]["name"],
      channel["description"]
    }) do
      if text
        and text ~= cjson.null
        and string.match(string.lower(text), "tistory") then
        local source_host = clip["sourceUrl"]
          and clip["sourceUrl"] ~= cjson.null
          and string.match(clip["sourceUrl"], "^https?://([^/?#]+)")
        if not source_host then
          error("No source site found for Tistory sourced video.")
        end
        if context["tistory"] then
          return true
        end
        context["tistory_referer"] = "https://" .. source_host .. "/"
        print("Video came from Tistory at " .. context["tistory_referer"] .. ".")
        context["tistory"] = true
        check("https://play-tv.kakao.com/api/v1/ft/playmeta/cliplink/" .. item_value .. "?fields=@html5vod&service=daum_tistory&type=VOD")
        check("https://play-tv.kakao.com/api/v3/ft/cliplinks/" .. item_value .. "/startAfter?service=daum_tistory")
        for video_id, _ in pairs(context["video_ids"]) do
          check_video_id(video_id)
        end
        return true
      end
    end
    return false
  end

  if item_type == "video"
    and not context["init"] then
    if status_code == 200
      and string.match(url, "^https?://tv%.kakao%.com/v/" .. item_value .. "$") then
      init_video_urls()
    elseif string.match(url, "^https?://tv%.kakao%.com/channel/[0-9]+/cliplink/" .. item_value .. "$") then
      if status_code == 404
        and not context["tistory"] then
        context["channel_clip_404"] = true
        check("https://tv.kakao.com/api/v1/ft/cliplinks/" .. item_value)
      elseif status_code == 200
        or context["tistory"] then
        init_video_urls()
      end
    end
  end

  if status_code == 200
    and item_type ~= "asset"
    and not string.match(url, "%.mp4%?")
    and not string.match(url, "%.m4s%?")
    and not string.match(url, "%.ts%?")
    and not string.match(url, "%.m4a%?")
    and not string.match(url, "%.aac%?")
    and allowed(url) then
    local html = read_file(file)
    if item_type == "channel"
      and string.match(url, "^https?://tv%.kakao%.com/channel/" .. item_value .. "/info$") then
      check("https://tv.kakao.com/channel/" .. item_value .. "/")
      check("https://tv.kakao.com/channel/" .. item_value .. "/video")
      check("https://tv.kakao.com/channel/" .. item_value .. "/playlist")
      check("https://tv.kakao.com/channel/" .. item_value .. "/bg.png")
      for _, pattern in ipairs({
        "(https://img1%.kakaocdn%.net/thumb/R[0-9]+x0/%?fname=[^%)\"']+)",
        "(//img1%.kakaocdn%.net/thumb/R[0-9]+x0/%?fname=[^%)\"']+)"
      }) do
        for newurl in string.gmatch(html, pattern) do
          if string.match(newurl, "^//") then
            newurl = "https:" .. newurl
          end
          ids[string.lower(newurl)] = true
          check(newurl)
        end
      end
    elseif item_type == "channel"
      and string.match(url, "^https?://tv%.kakao%.com/channel/" .. item_value .. "/video$") then
      check(
        "https://tv.kakao.com/api/v1/ft/channels/" .. item_value
        .. "/videolinks?sort=CreateTime&fulllevels=clipLinkList%2CliveLinkList"
        .. "&fields=ccuCount%2CisShowCcuCount%2CthumbnailUrl%2C-user"
        .. "%2C-clipChapterThumbnailList%2C-tagList&size=20&page=1"
      )
    elseif string.match(url, "/readyNplay%?") then
      json = cjson.decode(html)
      local location = json["kampLocation"]
      context["kamp_id"] = location["id"]
      local kamp_uuid = json["uuid"]
      check(json["metaUrl"])
      if json["seekUrl"]
        and json["seekUrl"] ~= cjson.null then
        check(json["seekUrl"])
      end
      check_video_id(context["kamp_id"])
      if not kamp_uuid
        or kamp_uuid == cjson.null
        or string.len(kamp_uuid) == 0 then
        kamp_uuid = "null"
      end
      check(
        "https://kamp.kakao.com/vod/v1/src/" .. context["kamp_id"]
        .. "?tid=" .. json["tid"] .. "&param_auth=true",
        {
          ["x-kamp-auth"] = "Bearer " .. location["token"],
          ["x-kamp-player"] = "monet_html5",
          ["x-kamp-version"] = "3.48.0",
          ["x-kamp-uuid"] = kamp_uuid
        }
      )
    elseif string.match(url, "^https?://tv%.kakao%.com/api/v1/ft/cliplinks/[0-9]+$") then
      json = cjson.decode(html)
      local clip = json["clip"]
      if check_tistory_source(clip, json["channel"]) then
        if context["channel_clip_404"] then
          init_video_urls()
        end
      elseif context["channel_clip_404"] then
        error("Video is likely a Daum video.")
      end
      check_clip_thumbnails(clip)
      scan_json_urls(clip)
      scan_json_urls(json["channel"])
    elseif string.match(url, "/playmeta/cliplink/") then
      json = cjson.decode(html)
      local clip_link = json["clipLink"]
      if skipped_channel_ids[tostring(clip_link["channel"]["user"]["id"])] then
        io.stdout:write("Video belongs to a skipped channel.\n")
        io.stdout:flush()
        bad_items[item_name] = true
        context["skipped_channel"] = true
        scan_json_urls(json, true)
        return urls
      end
      if string.match(url, "/playmeta/cliplink/([^?]+)") == item_value then
        context["channel_id"] = clip_link["channelId"]
        check("https://tv.kakao.com/channel/" .. context["channel_id"] .. "/cliplink/" .. item_value)
        if not context["tistory"] then
          check(
            "https://tv.kakao.com/channel/" .. context["channel_id"] .. "/cliplink/" .. item_value
            .. "?metaObjectType=Channel"
          )
        end
        check(
          "https://tv.kakao.com/embed/player/cliplink/" .. item_value
          .. "?service=kakao_tv&section=channel&autoplay=1&profile=HIGH&wmode=transparent"
        )
        for video_id, _ in pairs(context["video_ids"]) do
          check("https://tv.kakao.com/channel/" .. context["channel_id"] .. "/cliplink/" .. video_id)
        end
        check(ready_nplay_url("https://tv.kakao.com/channel/" .. context["channel_id"] .. "/cliplink/" .. item_value))
        if not context["tistory"] then
          check(ready_nplay_url(
            "https://tv.kakao.com/channel/" .. context["channel_id"] .. "/cliplink/"
            .. item_value .. "?metaObjectType=Channel"
          ))
        end
      end
      local clip = clip_link["clip"]
      check_tistory_source(clip, clip_link["channel"])
      if clip["vid"]
        and clip["vid"] ~= cjson.null then
        check_video_id(clip["vid"])
      end
      check_clip_thumbnails(clip)
      scan_json_urls(clip)
      scan_json_urls(clip_link["channel"])
      scan_json_urls(json["kakaoLink"])
    elseif string.match(url, "/katz/v1/close/cliplink/") then
      json = cjson.decode(html)
      if json["vid"]
        and json["vid"] ~= cjson.null then
        check_video_id(json["vid"])
      end
    elseif string.match(url, "^https?://tv%.kakao%.com/api/v1/ft/cliplinks/[0-9]+/playlistclips$") then
      json = cjson.decode(html)
      for _, playlist_clip in ipairs(json["list"]) do
        if tostring(playlist_clip["clipLinkId"]) == item_value then
          local playlist = playlist_clip["playlist"]
          local channel_id = playlist["channelId"] or context["channel_id"]
          local playlist_id = playlist_clip["playlistId"] or playlist["id"]
          check(
            "https://tv.kakao.com/channel/" .. channel_id .. "/cliplink/" .. item_value
            .. "?playlistId=" .. playlist_id .. "&metaObjectType=Playlist"
          )
        end
      end
    elseif string.match(url, "^https?://tv%.kakao%.com/api/v1/ft/playlists/[0-9]+$") then
      json = cjson.decode(html)
      context["channel_id"] = json["channelId"]
      check(
        "https://tv.kakao.com/api/v1/ft/playlists/" .. item_value .. "/playlistclips"
        .. "?fields=-*,hasMore,list,id,playlistId,clipLinkId,nextPlaylistClipId&size=100"
      )
      scan_json_urls(json)
    elseif string.match(url, "^https?://tv%.kakao%.com/api/v1/ft/playlists/[0-9]+/playlistclips%?") then
      json = cjson.decode(html)
      if json["hasMore"] then
        check(
          "https://tv.kakao.com/api/v1/ft/playlists/" .. item_value .. "/playlistclips"
          .. "?fields=-*,hasMore,list,id,playlistId,clipLinkId,nextPlaylistClipId&size=100&beginId=" .. json["list"][#json["list"]]["nextPlaylistClipId"]
        )
      end
    elseif string.match(url, "^https?://tv%.kakao%.com/api/v1/ft/channels/([0-9]+)/videolinks%?") == item_value then
      json = cjson.decode(html)
      scan_json_urls(json)
      for _, clip_link in ipairs(json["clipLinkList"]) do
        local clip = clip_link["clip"]
        if clip["thumbnailUrl"]
          and clip["thumbnailUrl"] ~= cjson.null then
          for _, source in ipairs({
            clip["thumbnailUrl"],
            string.match(clip["thumbnailUrl"], "^([^?]+)%?")
          }) do
            local thumb_url = "https://img1.kakaocdn.net/thumb/C240x140.fjpg.q75/?fname=" .. urlparse.escape(source)
            ids[string.lower(thumb_url)] = true
            check(thumb_url)
          end
        end
      end
      local page = string.match(url, "[?&]page=([0-9]+)")
      if json["hasMore"] then
        check(
          "https://tv.kakao.com/api/v1/ft/channels/" .. item_value .. "/videolinks"
          .. "?sort=CreateTime&fulllevels=clipLinkList%2CliveLinkList"
          .. "&fields=ccuCount%2CisShowCcuCount%2CthumbnailUrl%2C-user"
          .. "%2C-clipChapterThumbnailList%2C-tagList&size=20&page=" .. (tonumber(page) + 1)
        )
      end
    elseif string.match(url, "^https?://kamp%.kakao%.com/vod/v1/src/") then
      json = cjson.decode(html)
      context["kamp_id"] = json["vid"]
      if json["thumbnail"]
        and json["thumbnail"] ~= cjson.null then
        local is_frame_thumbnail = string.match(json["thumbnail"], "/tvpot/thumb/[^/]+/[0-9]+%.jpg")
          or string.match(json["thumbnail"], "/dna/kamp/source/[^/]+/[0-9]+%.jpg")
          or string.match(json["thumbnail"], "[?&]kamp_tidx=")
        check_thumbnails(
          json["thumbnail"],
          not is_frame_thumbnail,
          false
        )
      end
      local selected_stream = nil
      for _, stream in ipairs(json["streams"]) do
        if stream["profile"] == "HIGH" then
          if string.match(stream["url"], "/dash/")
            and string.match(stream["url"], "%.mpd%?") then
            selected_stream = stream
            break
          elseif not selected_stream then
            selected_stream = stream
          end
        end
      end
      if not selected_stream then
        selected_stream = json["streams"][1]
      end
      if check(selected_stream["url"]) then
        context["video_queued"] = true
      end
      if selected_stream["name"]
        and selected_stream["name"] ~= cjson.null then
        check(
          "https://tv.kakao.com/api/v3/ft/cliplinks/" .. item_value .. "/startAfter"
          .. "?service=kakao_tv&rslu=" .. urlparse.escape(selected_stream["name"])
        )
      end
      local seeking = json["seeking"]
      if seeking
        and seeking ~= cjson.null then
        if seeking["urls"]
          and seeking["urls"] ~= cjson.null then
          for _, thumb in pairs(seeking["urls"]) do
            check_thumbnails(thumb, false, true)
            local index = string.match(thumb, "/" .. context["kamp_id"] .. "/([0-9]+)%.jpg")
            if index then
              local thumb_url = "https://t1.kakaocdn.net/thumb/C180x100/"
                .. "?fname=" .. urlparse.escape("http://t1.daumcdn.net/tvpot/thumb/" .. context["kamp_id"] .. "/" .. index .. ".jpg")
              ids[string.lower(thumb_url)] = true
              check(thumb_url)
            end
          end
        end
        if seeking["url"]
          and seeking["url"] ~= cjson.null then
          ids[string.lower(seeking["url"])] = true
          check(seeking["url"])
        end
      end
    elseif string.match(url, "%.m3u8") then
      local function get_attr(text, attr)
        return string.match(text, attr .. '="([^"]*)"')
          or string.match(text, attr .. "=([^,]+)")
      end
      local stream_variants = {}
      local audio_media = {}
      local pending_stream_attrs = nil
      for line in string.gmatch(html, "([^\r\n]+)") do
        line = string.match(line, "^%s*(.-)%s*$")
        local stream_attrs = string.match(line, "^#EXT%-X%-STREAM%-INF:(.+)$")
        if stream_attrs then
          pending_stream_attrs = stream_attrs
        else
          local media_attrs = string.match(line, "^#EXT%-X%-MEDIA:(.+)$")
          if media_attrs then
            local media_uri = get_attr(media_attrs, "URI")
            if get_attr(media_attrs, "TYPE") == "AUDIO"
              and media_uri then
              table.insert(audio_media, {
                ["attrs"]=media_attrs,
                ["uri"]=media_uri,
                ["group_id"]=get_attr(media_attrs, "GROUP-ID"),
                ["default"]=string.lower(get_attr(media_attrs, "DEFAULT") or "") == "yes"
              })
            end
          elseif pending_stream_attrs
            and string.len(line) > 0
            and not string.match(line, "^#") then
            local width, height = string.match(get_attr(pending_stream_attrs, "RESOLUTION"), "([0-9]+)x([0-9]+)")
            table.insert(stream_variants, {
              ["attrs"]=pending_stream_attrs,
              ["uri"]=line,
              ["pixels"]=tonumber(width) * tonumber(height)
            })
            pending_stream_attrs = nil
          end
        end
      end
      if #stream_variants > 0 then
        local selected_variant = nil
        for _, variant in ipairs(stream_variants) do
          if not selected_variant
            or variant["pixels"] > selected_variant["pixels"] then
            selected_variant = variant
          end
        end
        check_manifest_url(selected_variant["uri"])
        local audio_group = get_attr(selected_variant["attrs"], "AUDIO")
        local selected_audio = nil
        for _, media in ipairs(audio_media) do
          if (not audio_group or media["group_id"] == audio_group)
            and (not selected_audio or media["default"]) then
            selected_audio = media
          end
        end
        if selected_audio then
          check_manifest_url(selected_audio["uri"])
        end
      else
        for newurl in string.gmatch(html, '[Uu][Rr][Ii]="([^"]+)"') do
          check_manifest_url(newurl)
        end
        for newurl in string.gmatch(html, "[Uu][Rr][Ii]='([^']+)'") do
          check_manifest_url(newurl)
        end
        for line in string.gmatch(html, "([^\r\n]+)") do
          line = string.match(line, "^%s*(.-)%s*$")
          if string.len(line) > 0
            and not string.match(line, "^#") then
            check_manifest_url(line)
          end
        end
      end
    elseif string.match(url, "%.mpd") then
      local function get_attr(text, attr)
        return string.match(text, "^" .. attr .. '="([^"]+)"')
          or string.match(text, "%s" .. attr .. '="([^"]+)"')
      end
      local function format_template(template, number, repr_id, time)
        template = string.gsub(template, "%$RepresentationID%$", repr_id or "")
        template = string.gsub(template, "%$Number%%0([0-9]+)d%$", function(width)
          return string.format("%0" .. width .. "d", number)
        end)
        template = string.gsub(template, "%$Number%$", tostring(number))
        if time then
          template = string.gsub(template, "%$Time%$", tostring(time))
        end
        if string.match(template, "%$[^$]+%$") then
          error("Template not completed.")
        end
        return template
      end
      local duration = string.match(html, 'mediaPresentationDuration="([^"]+)"')
        or string.match(html, '<Period[^>]-duration="([^"]+)"')
      duration = (tonumber(string.match(duration, "([0-9%.]+)H")) or 0) * 3600
        + (tonumber(string.match(duration, "([0-9%.]+)M")) or 0) * 60
        + (tonumber(string.match(duration, "([0-9%.]+)S")) or 0)
      local representations = {}
      local function add_representation(adapt_attrs, repr_attrs, repr_body)
        local repr_id = get_attr(repr_attrs, "id")
        local text = string.lower(adapt_attrs .. " " .. repr_attrs)
        local kind = "video"
        if string.match(string.lower(repr_id), "^a[_%-]")
          or string.match(text, 'contenttype="audio"')
          or string.match(text, 'mimetype="audio/')
          or string.match(text, 'codecs="mp4a') then
          kind = "audio"
        end
        local pixels = 0
        if kind == "video" then
          pixels = tonumber(get_attr(repr_attrs, "width") or get_attr(adapt_attrs, "width"))
            * tonumber(get_attr(repr_attrs, "height") or get_attr(adapt_attrs, "height"))
        end
        local representation = {
          ["id"]=repr_id,
          ["kind"]=kind,
          ["pixels"]=pixels,
          ["templates"]={}
        }
        for attrs, body in string.gmatch(repr_body, "<SegmentTemplate([^>]*)>(.-)</SegmentTemplate>") do
          table.insert(representation["templates"], {attrs, body, repr_id})
        end
        for attrs in string.gmatch(repr_body, "<SegmentTemplate([^>]*)/>") do
          table.insert(representation["templates"], {attrs, "", repr_id})
        end
        if #representation["templates"] > 0 then
          table.insert(representations, representation)
        end
      end
      for adapt_attrs, adapt_body in string.gmatch(html, "<AdaptationSet([^>]*)>(.-)</AdaptationSet>") do
        for repr_attrs, repr_body in string.gmatch(adapt_body, "<Representation([^>]*)>(.-)</Representation>") do
          add_representation(adapt_attrs, repr_attrs, repr_body)
        end
      end
      if #representations == 0 then
        for repr_attrs, repr_body in string.gmatch(html, "<Representation([^>]*)>(.-)</Representation>") do
          add_representation("", repr_attrs, repr_body)
        end
      end
      local selected_representations = {}
      local selected_video = nil
      for _, representation in ipairs(representations) do
        if representation["kind"] == "audio" then
          selected_representations[representation] = true
        else
          if not selected_video
            or representation["pixels"] > selected_video["pixels"] then
            selected_video = representation
          end
        end
      end
      if selected_video then
        selected_representations[selected_video] = true
      end
      for _, representation in ipairs(representations) do
        if selected_representations[representation] then
          for _, segment_template in ipairs(representation["templates"]) do
            local attrs = segment_template[1]
            local body = segment_template[2]
            local repr_id = segment_template[3]
            local initialization = get_attr(attrs, "initialization")
            local media = get_attr(attrs, "media")
            local timescale = tonumber(get_attr(attrs, "timescale")) or 1
            local start_number = tonumber(get_attr(attrs, "startNumber")) or 1
            local number = start_number
            if initialization then
              check_manifest_url(format_template(initialization, number, repr_id))
            end
            if media then
              if string.match(body, "<S") then
                local current_time = nil
                for s_attrs in string.gmatch(body, "<S([^>]*)") do
                  local segment_duration = tonumber(get_attr(s_attrs, "d"))
                  local repeat_count = tonumber(get_attr(s_attrs, "r")) or 0
                  current_time = tonumber(get_attr(s_attrs, "t")) or current_time or 0
                  if repeat_count < 0 then
                    repeat_count = math.ceil((duration * timescale - current_time) / segment_duration) - 1
                  end
                  for _ = 0, repeat_count do
                    check_manifest_url(format_template(media, number, repr_id, current_time))
                    current_time = current_time + segment_duration
                    number = number + 1
                  end
                end
              else
                local segment_duration = tonumber(get_attr(attrs, "duration"))
                local count = math.ceil(duration * timescale / segment_duration)
                for i = 0, count - 1 do
                  check_manifest_url(format_template(media, start_number + i, repr_id))
                end
              end
            end
          end
        end
      end
    elseif string.match(url, "^https?://tv%.kakao%.com/")
      or string.match(url, "^https?://play%-tv%.kakao%.com/embed/") then
      for newurl in string.gmatch(string.gsub(html, "&[qQ][uU][oO][tT];", '"'), '([^"]+)') do
        checknewurl(newurl)
      end
      for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
        checknewurl(newurl)
      end
      for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, "[^%-]src='([^']+)'") do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, '[^%-]src="([^"]+)"') do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
        newurl = string.gsub(newurl, "^['\"]", "")
        newurl = string.gsub(newurl, "['\"]$", "")
        checknewurl(newurl)
      end
      html = string.gsub(html, "&gt;", ">")
      html = string.gsub(html, "&lt;", "<")
      for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
        checknewurl(newurl)
      end
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  is_initial_url = false
  if status_code == 200
    and http_stat["len"] == 0
    and not string.match(url["url"], "/startAfter%?") then
    retry_url = true
    return false
  end
  if status_code == 403
    and item_type == "video"
    and string.match(url["url"], "/readyNplay%?") then
    local json = cjson.decode(read_file(http_stat["local_file"]))
    if json["code"] == "GeoBlocked" then
      abort_item()
      error("Video is geoblocked.")
    end
  end
  if status_code ~= 200
    and item_type == "playlist"
    and string.match(url["url"], "^https?://tv%.kakao%.com/api/v1/ft/playlists/" .. item_value .. "$") then
    abort_item()
    return false
  end
  if status_code ~= 200
    and item_type == "channel"
    and string.match(url["url"], "^https?://tv%.kakao%.com/channel/" .. item_value .. "/info$") then
    abort_item()
    return false
  end
  local allowed_channel_clip = false
  if status_code == 404
    and item_type == "video" then
    local channel_clip_id = string.match(url["url"], "^https?://tv%.kakao%.com/channel/[0-9]+/cliplink/([^/?#]+)$")
    if channel_clip_id then
      channel_clip_id = urlparse.unescape(channel_clip_id)
      allowed_channel_clip =
        channel_clip_id == item_value
        or context["video_ids"][channel_clip_id]
        or context["video_ids"][string.gsub(channel_clip_id, "@my$", "")]
    end
  end
  local allowed_thumbnail_404 = false
  if status_code == 404 then
    for _, pattern in pairs({
      "^https?://t1%.kakaocdn%.net/thumb/",
      "^https?://img1%.kakaocdn%.net/thumb/",
      "^https?://img1%.daumcdn%.net/thumb/",
      "^https?://t1%.kakaocdn%.net/tvpot/thumb/",
      "^https?://t1%.daumcdn%.net/tvpot/thumb/",
      "^https?://thumb%.kakaocdn%.net/dna/kamp/source/"
    }) do
      if string.match(url["url"], pattern) then
        allowed_thumbnail_404 = true
      end
    end
  end
  if status_code ~= 200
    and status_code ~= 206
    and status_code ~= 301
    and status_code ~= 302
    and not (
      status_code == 404
      and (allowed_channel_clip or allowed_thumbnail_404)
    ) then
    retry_url = true
    return false
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 6
    if status_code == 401 or status_code == 403 or status_code == 404 then
      tries = maxtries + 1
    end
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    if status_code == 200 or status_code == 206 then
      if not seen_200[url["url"]] then
        seen_200[url["url"]] = 0
      end
      seen_200[url["url"]] = seen_200[url["url"]] + 1
    end
    downloaded[url["url"]] = true
  end

  if status_code == 301 or status_code == 302 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["kakaotv-xy62olcixrmgj8hi"] = discovered_items
  }) do
    print("queuing for", string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  found_video()
  if abortgrab then
    abort_item()
  end
  return exit_status
end
