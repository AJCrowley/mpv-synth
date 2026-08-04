import os
import tempfile
import sys
import json
import pickle
from babelfish import Language, language
from subliminal import Video, download_subtitles, list_subtitles, save_subtitles, scan_video, region
from subliminal.core import ProviderPool

region.configure('dogpile.cache.memory')
cache_file = os.path.join(tempfile.gettempdir(), "subliminal_subtitles.cache")
operation = sys.argv[1]

match operation:
    case 'list':
        if os.path.exists(cache_file):
            os.remove(cache_file)
        title_text = sys.argv[2]
        lang = sys.argv[3].lower()
        # Handle 2-letter, 3-letter, or full name
        try:
            if len(lang) == 2:
                lang = Language.fromalpha2(lang)
            elif len(lang) == 3:
                lang = Language(lang)
            else:
                lang = Language.fromname(lang.title())  # e.g., "english" → "English"
        except Exception:
            print("Invalid language")
            sys.exit(1)

        video = scan_video(title_text)
        subtitles = list_subtitles([video], {lang})
        with open(cache_file, "wb") as f:
            pickle.dump({
                "video": video,
                "subtitles": subtitles
            }, f)
        
    case 'download':
        title_text = sys.argv[2]
        lang = sys.argv[3].lower()
        sub_id = sys.argv[4]
        sub_provider = sys.argv[5]
        dir = sys.argv[6]

        with open(cache_file, "rb") as f:
            cache = pickle.load(f)

        video = cache["video"]
        subtitles = cache["subtitles"]
        for sub in subtitles[video]:
            if str(sub.id) == sub_id:
                selected = sub
                break

        pool = ProviderPool(providers=[sub_provider])
        pool.download_subtitle(selected)
        video = scan_video(title_text)
        save_subtitles(video, [selected])
        os.remove(cache_file)
        sys.exit(0)

    case 'search':
        if os.path.exists(cache_file):
            os.remove(cache_file)
        title_text = sys.argv[2]
        search_text = sys.argv[3]
        lang = sys.argv[4].lower()
        # Handle 2-letter, 3-letter, or full name
        try:
            if len(lang) == 2:
                lang = Language.fromalpha2(lang)
            elif len(lang) == 3:
                lang = Language(lang)
            else:
                lang = Language.fromname(lang.title())  # e.g., "english" → "English"
        except Exception:
            print("Invalid language")
            sys.exit(1)

        video = Video.fromname(search_text)
        subtitles = list_subtitles([video], {lang})
        with open(cache_file, "wb") as f:
            pickle.dump({
                "video": video,
                "subtitles": subtitles
            }, f)

# Convert subtitles to JSON-serializable format
def serialize_subtitle(s):
    return {
        'provider': s.provider_name,
        'language': str(s.language),
        'id': s.id,
        'title': getattr(s, 'title', None),
        'series': getattr(s, 'series', None),
        'season': getattr(s, 'season', None),
        'episode': getattr(s, 'episode', None),
    }

result = [serialize_subtitle(s) for s in subtitles[video]]
print(json.dumps(result))