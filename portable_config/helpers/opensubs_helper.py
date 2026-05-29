from multiprocessing import pool
import sys
import json
from babelfish import Language
from subliminal import download_subtitles, list_subtitles, save_subtitles, scan_video, region
from subliminal.core import ProviderPool

region.configure('dogpile.cache.memory')

operation = sys.argv[1]

video_path = sys.argv[2]
lang_input = sys.argv[3].lower()

# Handle 2-letter, 3-letter, or full name
try:
    if len(lang_input) == 2:
        lang = Language.fromalpha2(lang_input)
    elif len(lang_input) == 3:
        lang = Language(lang_input)
    else:
        lang = Language.fromname(lang_input.title())  # e.g., "english" → "English"
except Exception:
    print("Invalid language")
    sys.exit(1)

# Wrap in a set
languages = {lang}

video = scan_video(video_path)
subtitles = list_subtitles([video], languages)

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
if sys.argv[1] == 'download' and result:

    for sub in subtitles[video]:
        if str(sub.id) == sys.argv[4]:
            selected = sub
            break
    
    provider_name = sys.argv[5]
    pool = ProviderPool(providers=[provider_name])
    pool.download_subtitle(selected)
    save_subtitles(video, [selected])
    print("Download successful")
elif sys.argv[1] == 'list':
    print(json.dumps(result))
