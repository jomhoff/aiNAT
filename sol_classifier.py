"""Sol-only application worker. Frozen evaluated prompt; resumable per-photo cache."""
import argparse
import concurrent.futures
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tempfile
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone
from PIL import Image, ImageOps
from sol_pilot import MODEL, PROMPT, SCHEMA, payload, parse_response
from openai_key_setup import KEY_PATH

CONFIG = {'model': MODEL, 'prompt': PROMPT, 'schema': SCHEMA, 'detail': 'high', 'reasoning_effort': 'low', 'max_output_tokens': 2000, 'image_size': [900,480]}
CONFIG_ID = hashlib.sha256(json.dumps(CONFIG, sort_keys=True).encode()).hexdigest()
MORPHS = {'red_backed','lead_backed','cant_tell'}


def atomic_json(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w') as f: json.dump(value, f, indent=2)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def read_json(path, default):
    return json.loads(Path(path).read_text()) if Path(path).exists() else default


def usage_cost(usage):
    cached = usage.get('input_tokens_details',{}).get('cached_tokens',0)
    return ((usage.get('input_tokens',0)-cached)*2 + cached*.1 + usage.get('output_tokens',0)*10)/1e6


def cache_path(data, photo_id, image_hash, config_id=CONFIG_ID):
    key = hashlib.sha256(f'{config_id}:{photo_id}:{image_hash}'.encode()).hexdigest()
    return Path(data)/'sol'/'cache'/f'{key}.json'


def combine_photos(photos):
    if not photos: return 'cant_tell', 'No photos available.'
    values = {p['morph'] for p in photos}
    if values == {'red_backed'} or values == {'lead_backed'}:
        return next(iter(values)), 'All photos agree.' if len(photos)>1 else photos[0]['reason']
    if 'cant_tell' in values: return 'cant_tell', 'One or more photos need review. '+ '; '.join(dict.fromkeys(p['reason'] for p in photos if p['morph']=='cant_tell'))
    return 'cant_tell', 'Photos disagree on the morph. Review this observation.'


def import_evaluation_cache(data):
    """Reuse paid API answers, without importing reference labels or changing predictions."""
    data=Path(data); count=0
    root=data/'sol-large-test-20261022'
    pairs=[]
    if (root/'answers.json').exists() and (root/'manifest.json').exists():
        manifest={r['code']:r for r in read_json(root/'manifest.json',[])}
        for a in read_json(root/'answers.json',[]):
            r=manifest.get(a['code'])
            if r: pairs.append((a,r['photo_id'],Path(r['image_path']),r['image_sha256']))
    old=data/'vision-2fc761fc4bb8'
    if (old/'sol-api-pilot'/'answers.json').exists():
        # IDs identify cache entries only; reference morphs are never copied.
        ids={r['code']:r['photo_id'] for r in read_json(old/'direct-vision-pilot'/'scoring-key.json',[])}
        for a in read_json(old/'sol-api-pilot'/'answers.json',[]):
            if a['code'] in ids: pairs.append((a,ids[a['code']],old/'direct-vision-pilot'/f"{a['code']}.png",None))
    for a,photo_id,image,expected_hash in pairs:
        if not image.exists() or a.get('actual_model')!=MODEL: continue
        digest=hashlib.sha256(image.read_bytes()).hexdigest()
        if expected_hash and digest!=expected_hash: continue
        path=cache_path(data,photo_id,digest)
        if not path.exists():
            answer={k:a[k] for k in ('morph','reason','response_id','actual_model','usage','estimated_cost_usd') if k in a}
            answer.update(config_id=CONFIG_ID,photo_id=str(photo_id),image_sha256=digest,imported_evaluation=True)
            atomic_json(path,answer);count+=1
    return count


class Stopped(Exception): pass


class Worker:
    def __init__(self, data, status, stop_file, budget, key=None, requester=None, recipe=None):
        self.data=Path(data);self.status=Path(status);self.stop_file=Path(stop_file);self.budget=budget
        self.recipe=recipe;self.config_id=recipe['config_id'] if recipe else CONFIG_ID
        self.key=key;self.requester=requester or self.api_request
        self.lock=threading.Lock();self.cost=0.;self.api_calls=0;self.cached=0;self.error=None;self.budget_hit=False

    def check(self):
        with self.lock:
            if self.error or self.stop_file.exists(): raise Stopped()
            if self.cost>=self.budget:
                self.budget_hit=True;raise Stopped()

    def image_path(self, photo):
        photo_id=str(photo['id'])
        if photo.get('image_path'):
            candidate=Path(photo['image_path']).resolve()
            # Local uploads/manifests may only reference this project's own data directory.
            if not candidate.is_relative_to(self.data.resolve()) or not candidate.is_file():
                raise ValueError('Local photo is outside this project.')
            return candidate
        if not re.fullmatch(r'[0-9]+',photo_id): raise ValueError('Invalid photo ID.')
        # Same saved full-photo input used in evaluation when available.
        existing=self.data/'annotations'/'images'/f'{photo_id}.png'
        if existing.exists(): return existing
        target=self.data/'sol'/'images'/f'{photo_id}.png'
        if target.exists(): return target
        url=photo['url']
        if not re.match(r'^https://(?:inaturalist-open-data\.s3\.amazonaws\.com|static\.inaturalist\.org)/photos/[0-9]+/',url):
            raise ValueError('Unsupported photo source. Use an iNaturalist photo.')
        req=urllib.request.Request(url,headers={'User-Agent':'SalamanderMorphReview/2.0'})
        with urllib.request.urlopen(req,timeout=45) as response: raw=response.read(30*1024*1024+1)
        if len(raw)>30*1024*1024: raise ValueError('Photo exceeds 30 MB.')
        with Image.open(io.BytesIO(raw)) as image:
            image=ImageOps.exif_transpose(image).convert('RGB')
            image.thumbnail((900,480),Image.Resampling.LANCZOS)
            target.parent.mkdir(parents=True,exist_ok=True)
            fd,tmp=tempfile.mkstemp(dir=target.parent,suffix='.png');os.close(fd)
            try: image.save(tmp,format='PNG');os.replace(tmp,target)
            finally:
                if os.path.exists(tmp):os.unlink(tmp)
        return target

    def request_payload(self, image):
        if self.recipe:
            from project_model import recipe_payload
            return recipe_payload(self.recipe,image)
        return payload(image)

    def api_request(self, image):
        req=urllib.request.Request('https://api.openai.com/v1/responses', data=json.dumps(self.request_payload(image)).encode(), headers={'Authorization':'Bearer '+self.key,'Content-Type':'application/json'},method='POST')
        try:
            with urllib.request.urlopen(req,timeout=180) as response: return json.load(response)
        except urllib.error.HTTPError as e:
            message={401:'API key rejected. Run Configure OpenAI.command with the full secret key.',403:'API access denied. Check project permissions.',429:'API quota or rate limit reached. Check API billing and limits.'}.get(e.code,'API request failed.')
            raise RuntimeError(f'{message} HTTP {e.code}. No automatic retry.') from None
        except (OSError,ValueError):
            raise RuntimeError('API connection interrupted. Completed answers are saved; an interrupted request may have incurred usage. No automatic retry.') from None

    def classify_photo(self,photo):
        self.check()
        try:
            image=self.image_path(photo)
        except (ValueError,OSError,urllib.error.URLError):
            return dict(photo_id=str(photo['id']),morph='cant_tell',reason='Photo could not be loaded. Review it manually.',error=True,cached=False)
        digest=hashlib.sha256(image.read_bytes()).hexdigest();path=cache_path(self.data,photo['id'],digest,self.config_id)
        if path.exists():
            answer=read_json(path,{})
            with self.lock:self.cached+=1
            return dict(answer,cached=True)
        self.check()
        try: response=self.requester(image)
        except Exception as e:
            with self.lock:self.error=str(e)
            raise Stopped() from None
        usage=response.get('usage',{});cost=usage_cost(usage)
        answer=dict(photo_id=str(photo['id']),image_sha256=digest,config_id=self.config_id,response_id=response.get('id'),actual_model=response.get('model'),usage=usage,estimated_cost_usd=cost,morph='cant_tell',reason='Response could not be interpreted; manual review required.')
        # Persist paid response before parsing, so parse failures never trigger paid repeats.
        atomic_json(path,answer)
        try:
            if self.recipe:
                from project_model import parse_recipe_response
                answer.update(parse_recipe_response(response,self.recipe))
            else:answer.update(parse_response(response))
        except (ValueError,KeyError,TypeError):pass
        if not isinstance(answer.get('reason'),str):answer['reason']='Manual review required.'
        atomic_json(path,answer)
        with self.lock:self.cost+=cost;self.api_calls+=1
        return dict(answer,cached=False)

    def observation(self,row):
        photos=[]
        for photo in row.get('photos',[]):photos.append(self.classify_photo(photo))
        if self.recipe:
            from project_model import aggregate
            morph,reason,extra=aggregate(photos,self.recipe)
        else:morph,reason=combine_photos(photos);extra={}
        return dict(**extra,photo_mode=row.get('photo_mode','all'),id=str(row['id']),ai_morph=morph,reason=reason,photos=photos,model=MODEL,config_id=self.config_id,classified_at=datetime.now(timezone.utc).isoformat(),photo_ids=[str(p['id']) for p in row.get('photos',[])])

    def run(self,queue,output):
        existing=read_json(output,[]); results={str(r['id']):r for r in existing}
        completed=0;total=len(queue)
        def status(state,message):
            atomic_json(self.status,dict(state=state,message=message,completed=completed,total=total,estimated_cost_usd=self.cost,api_calls=self.api_calls,cached_photos=self.cached,config_id=self.config_id))
        status('running','Starting Sol classification…')
        pending=iter(queue)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            active={}
            def submit():
                try:self.check()
                except Stopped:return
                row=next(pending,None)
                if row is not None:active[pool.submit(self.observation,row)]=row
            for _ in range(4):submit()
            while active:
                done,_=concurrent.futures.wait(active,return_when=concurrent.futures.FIRST_COMPLETED)
                for future in done:
                    row=active.pop(future)
                    try:
                        answer=future.result();results[str(row['id'])]=answer;completed+=1
                        atomic_json(output,list(results.values()))
                    except Stopped:pass
                    except Exception:
                        self.error='Classification stopped unexpectedly. Completed predictions are saved.'
                    status('running',f'{completed}/{total} observations saved · estimated run cost ${self.cost:.3f} · {self.cached} cached photos reused')
                    submit()
        if self.error:state='error';message=self.error
        elif completed==total:state='complete';message=f'Complete: {completed} observations · estimated run cost ${self.cost:.3f} · {self.cached} cached photos reused'
        elif self.budget_hit:state='stopped';message='Cost stop reached. Completed answers saved; resume with a new run budget.'
        else:state='stopped';message='Stopped. Completed answers saved; resume to continue.'
        status(state,message)
        return read_json(self.status,{})


def main():
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--output',required=True);p.add_argument('--status',required=True);p.add_argument('--stop-file',required=True);p.add_argument('--budget',required=True,type=float);p.add_argument('--data',default='data');a=p.parse_args()
    lock_path=Path(a.data)/'sol'/'worker.lock';lock_path.parent.mkdir(parents=True,exist_ok=True)
    with lock_path.open('w') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            atomic_json(a.status,dict(state='error',message='Another Sol batch is already running. Stop it or wait for it to finish.'));return
        key=os.environ.get('OPENAI_API_KEY') or (KEY_PATH.read_text().strip() if KEY_PATH.exists() else '')
        if not key.startswith('sk-') or '...' in key or '…' in key or any(c.isspace() for c in key):
            atomic_json(a.status,dict(state='error',message='Configure a full OpenAI secret key using Configure OpenAI.command.'));return
        if not 0<a.budget<=100:raise SystemExit('Run budget must be greater than $0 and at most $100.')
        import_evaluation_cache(a.data)
        Worker(a.data,a.status,a.stop_file,a.budget,key=key).run(read_json(a.input,[]),a.output)

if __name__=='__main__':main()
