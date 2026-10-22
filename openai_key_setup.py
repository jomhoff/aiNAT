"""Save the current user's own key locally; never put a key in source control."""
import getpass, os, sys
from pathlib import Path
NEW_PATH=Path.home()/'.config/species-vision-lab/openai-api-key'
OLD_PATH=Path.home()/'.config/salamander-morphs/openai-api-key'
KEY_PATH=Path(os.environ['SPECIES_VISION_KEY_FILE']).expanduser() if os.environ.get('SPECIES_VISION_KEY_FILE') else (NEW_PATH if NEW_PATH.exists() or not OLD_PATH.exists() else OLD_PATH)
def save_key(key):
    key=key.strip()
    if not key.startswith('sk-') or '...' in key or '…' in key or any(c.isspace() for c in key):raise ValueError('Enter a full secret API key, not the shortened display value.')
    KEY_PATH.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd=os.open(KEY_PATH,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600);os.fchmod(fd,0o600)
    with os.fdopen(fd,'w') as f:f.write(key)
def main():
    key=sys.stdin.read() if '--stdin' in sys.argv else getpass.getpass('Your OpenAI API key (hidden): ')
    try:save_key(key)
    except ValueError as e:raise SystemExit(str(e))
    print('Your key is saved locally with owner-only permissions. No API requests or charges made.')
if __name__=='__main__':main()
