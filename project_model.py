"""Versioned, example-taught vision classifiers and honest held-out confidence evaluation."""
import argparse, base64, copy, fcntl, hashlib, json, math, os, re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from sol_classifier import Worker, CONFIG, CONFIG_ID, atomic_json, read_json
from sol_pilot import MODEL
from openai_key_setup import KEY_PATH


def fingerprint(value):return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def category_keys(project):return [c['key'] for c in project['categories']]
def validate_project(project):
    keys=category_keys(project)
    if not 2<=len(keys)<=12 or len(set(keys))!=len(keys):raise ValueError('Choose 2–12 distinct categories.')
    if any(not re.fullmatch(r'[a-z][a-z0-9_]{0,39}',k) or k in ('cant_tell','unclassified') for k in keys):raise ValueError('Category keys must be unique lowercase identifiers; uncertain and unclassified are reserved.')
    if not project.get('task','').strip() or not project.get('species',{}).get('name'):raise ValueError('Specify a species and what to classify.')


def image_content(path):return {'type':'input_image','image_url':'data:image/png;base64,'+base64.b64encode(Path(path).read_bytes()).decode(),'detail':'high'}
def recipe_payload(recipe,image):
    for e in recipe['examples']:
        if hashlib.sha256(Path(e['image_path']).read_bytes()).hexdigest()!=e['image_sha256']:raise ValueError('A teaching image changed; rebuild the classifier.')
    content=[{'type':'input_text','text':recipe['prompt']}]
    for e in recipe['examples']:
        content.extend([{'type':'input_text','text':'Labeled teaching example: '+e['label']},image_content(e['image_path'])])
    content.extend([{'type':'input_text','text':'Now classify ONLY this new target photograph. The teaching images above are reference examples.'},image_content(image)])
    return dict(model=MODEL,store=False,reasoning={'effort':'low'},max_output_tokens=2000,input=[{'role':'user','content':content}],text={'format':{'type':'json_schema','name':'visual_classification','strict':True,'schema':recipe['schema']}})


def parse_recipe_response(response,recipe):
    if response.get('status')!='completed':return dict(morph='cant_tell',reason='Response incomplete or refused.',confidence=0,feature_visible=False)
    text=''.join(c.get('text','') for o in response.get('output',[]) if o.get('type')=='message' for c in o.get('content',[]) if c.get('type')=='output_text')
    a=json.loads(text)
    if a.get('morph') not in recipe['category_keys']+['cant_tell']:raise ValueError('Invalid category')
    if type(a.get('confidence')) is not int or not 0<=a['confidence']<=100 or type(a.get('feature_visible')) is not bool or not isinstance(a.get('reason'),str):raise ValueError('Invalid confidence or visibility')
    if not a['feature_visible']:a['morph']='cant_tell'
    return a


def aggregate(photos,recipe):
    values={p['morph'] for p in photos}
    visible=bool(photos) and all(p.get('feature_visible',False) for p in photos)
    confidence=min((p.get('confidence',0) for p in photos),default=0)
    label=next(iter(values)) if len(values)==1 and 'cant_tell' not in values and visible else 'cant_tell'
    reason='; '.join(dict.fromkeys(p['reason'] for p in photos)) if photos else 'No photos.'
    if len(values)>1:reason='Photos disagree. '+reason
    return label,reason,dict(raw_label=label,confidence=confidence,feature_visible=visible)


def metrics(rows):
    accepted=[r for r in rows if r['accepted_label']!='cant_tell'];correct=sum(r['accepted_label']==r['truth'] for r in accepted);n=len(accepted)
    interval=None
    if n:
        z=1.96;ph=correct/n;den=1+z*z/n;center=(ph+z*z/(2*n))/den;half=z*math.sqrt(ph*(1-ph)/n+z*z/(4*n*n))/den;interval=[center-half,center+half]
    return dict(n=len(rows),accepted=n,correct=correct,wrong=n-correct,uncertain=len(rows)-n,precision=correct/n if n else None,coverage=n/len(rows) if rows else 0,wilson_95=interval)


def calibrate(rows,keys,target=.98,min_accepted=10):
    thresholds={};evidence={}
    for key in keys:
        thresholds[key]=None
        for score in range(50,101):
            selected=[r for r in rows if r['raw_label']==key and r['feature_visible'] and r['confidence']>=score]
            if len(selected)>=min_accepted and sum(r['truth']==key for r in selected)/len(selected)>=target:
                thresholds[key]=score;break
        selected=[dict(r,accepted_label=key) for r in rows if thresholds[key] is not None and r['raw_label']==key and r['feature_visible'] and r['confidence']>=thresholds[key]]
        evidence[key]=metrics(selected)
    return dict(thresholds=thresholds,target_precision=target,min_accepted=min_accepted,calibration=evidence,warning='Selected empirical precision, not a calibrated probability or guaranteed future accuracy. Test set was not used to select thresholds.')


def apply_policy(row,policy):
    threshold=policy['thresholds'].get(row['raw_label'])
    return row['raw_label'] if threshold is not None and row['feature_visible'] and row['confidence']>=threshold else 'cant_tell'


def build_recipe(project,records,data,output,status):
    validate_project(project);data=Path(data);out=Path(output)
    # Download/normalize full photos without making any AI request.
    worker=Worker(data,status,out/'stop',1)
    prepared=[];seen_ids=set();parents={};hash_owner={}
    def find(x):
        parents.setdefault(x,x)
        if parents[x]!=x:parents[x]=find(parents[x])
        return parents[x]
    for i,r in enumerate(records):
        if (out/'stop').exists():
            atomic_json(status,dict(state='stopped',message='Training stopped; previous classifier retained.'));return
        if str(r['id']) in seen_ids:continue
        if r.get('label') not in category_keys(project):continue
        images=[]
        for photo in r['photos']:
            image=worker.image_path(photo);h=hashlib.sha256(image.read_bytes()).hexdigest()
            images.append(dict(id=str(photo['id']),image_path=str(image.resolve()),image_sha256=h))
            rid=str(r['id']);find(rid)
            if h in hash_owner:parents[find(rid)]=find(hash_owner[h])
            else:hash_owner[h]=rid
        if not images:continue
        seen_ids.add(str(r['id']));prepared.append(dict(id=str(r['id']),label=r['label'],photos=images))
        atomic_json(status,dict(state='running',message=f'Preparing labeled photos: {i+1}/{len(records)}'))
    groups=defaultdict(list)
    for r in prepared:groups[find(r['id'])].append(r)
    per_class=defaultdict(list)
    for group in groups.values():
        if len({r['label'] for r in group})>1:raise ValueError('Duplicate images have conflicting labels. Correct them before training.')
        per_class[group[0]['label']].append(group)
    if any(len(per_class[k])<5 for k in category_keys(project)):raise ValueError('Label at least 5 independent observations per category. Aim for 50+ per category for useful validation.')
    splits={'teaching':[],'calibration':[],'test':[]};examples=[]
    for k in category_keys(project):
        groups_k=sorted(per_class[k],key=lambda g:hashlib.sha256(('species-vision-v1:'+min(r['id'] for r in g)).encode()).hexdigest())
        n=len(groups_k);held=max(1,int(n*.2));train=groups_k[:n-2*held];cal=groups_k[n-2*held:n-held];test=groups_k[n-held:]
        for name,gs in [('teaching',train),('calibration',cal),('test',test)]:
            splits[name].extend(r for g in gs for r in g)
        for group in train[:min(2,len(train))]:
            r=group[0];im=r['photos'][0];examples.append(dict(label=k,observation_id=r['id'],image_path=im['image_path'],image_sha256=im['image_sha256']))
    # A bounded, balanced reference set keeps API costs manageable.
    descriptions='\n'.join(f"- {c['key']} ({c['label']}): {c['description']}" for c in project['categories'])
    prompt=f"""Classify a visible trait of {project['species']['name']} in the target photograph.
Task: {project['task']}
Categories:
{descriptions}
Use only visible evidence on the organism. Never infer a category from background, location, frequency, filenames or presumed demographics. Teaching examples illustrate the category definitions; judge the final target independently. Return cant_tell when the relevant feature is hidden, blurry, ambiguous, absent, or multiple organisms conflict. State whether the distinguishing feature is clearly visible. Give a self-assessed confidence integer 0–100 for the chosen category; this score is NOT a calibrated probability. Explain the actual visible evidence briefly. Prioritize avoiding wrong assignments over coverage."""
    schema={'type':'object','properties':{'morph':{'type':'string','enum':category_keys(project)+['cant_tell']},'reason':{'type':'string'},'confidence':{'type':'integer','minimum':0,'maximum':100},'feature_visible':{'type':'boolean'}},'required':['morph','reason','confidence','feature_visible'],'additionalProperties':False}
    recipe=dict(version=1,model=MODEL,project_id=project['id'],project_fingerprint=fingerprint({k:project[k] for k in ('id','species','task','categories')}),category_keys=category_keys(project),prompt=prompt,schema=schema,examples=examples,splits=splits,settings={'detail':'high','reasoning_effort':'low','max_output_tokens':2000,'image_size':[900,480],'photo_mode':project.get('photo_mode','all')})
    recipe['config_id']=fingerprint(recipe);out.mkdir(parents=True,exist_ok=True);atomic_json(out/'recipe.json',recipe)
    atomic_json(status,dict(state='complete',message=f"Classifier prepared with {len(examples)} teaching photos; {len(splits['calibration'])} calibration and {len(splits['test'])} test observations. No AI requests made.",config_id=recipe['config_id']))
    return recipe


def evaluate(recipe,data,out,status,stop_file,budget,key,requester=None):
    out=Path(out);rows=recipe['splits']['calibration']+recipe['splits']['test'];seen=set()
    teaching={r['id'] for r in recipe['splits']['teaching']}
    for r in rows:
        if r['id'] in seen or r['id'] in teaching:raise ValueError('Evaluation split leakage')
        seen.add(r['id'])
        for p in r['photos']:
            if hashlib.sha256(Path(p['image_path']).read_bytes()).hexdigest()!=p['image_sha256']:raise ValueError('An evaluation image changed; rebuild before evaluating.')
    w=Worker(data,status,stop_file,budget,key=key,requester=requester,recipe=recipe)
    state=w.run([dict(id=r['id'],photos=r['photos']) for r in rows],out/'evaluation_answers.json')
    if state['state']!='complete':return
    predictions={r['id']:r for r in read_json(out/'evaluation_answers.json',[]) if r['config_id']==recipe['config_id']}
    def scored(split):return [dict(id=r['id'],truth=r['label'],raw_label=predictions[r['id']]['raw_label'],confidence=predictions[r['id']]['confidence'],feature_visible=predictions[r['id']]['feature_visible']) for r in recipe['splits'][split]]
    calibration=scored('calibration');test=scored('test');policy=calibrate(calibration,recipe['category_keys']);policy['config_id']=recipe['config_id']
    for r in calibration+test:r['accepted_label']=apply_policy(r,policy)
    summary=dict(config_id=recipe['config_id'],policy=policy,calibration=metrics(calibration),test=metrics(test),test_per_prediction={k:metrics([r for r in test if r['accepted_label']==k]) for k in recipe['category_keys']},raw_test=metrics([dict(r,accepted_label=r['raw_label']) for r in test]),estimated_cost_usd=state['estimated_cost_usd'],note='Confidence is self-assessed; empirical thresholds selected only on calibration. Frozen test is now evaluated; changing the classifier requires a fresh independent audit.')
    atomic_json(out/'policy.json',policy);atomic_json(out/'evaluation_scored.json',dict(calibration=calibration,test=test));atomic_json(out/'evaluation_summary.json',summary)
    state.update(message=f"Evaluation complete: test {summary['test']['correct']}/{summary['test']['accepted']} accepted assignments correct; {summary['test']['uncertain']} sent for review.")
    atomic_json(status,state)


def main():
    p=argparse.ArgumentParser();p.add_argument('command',choices=['train','evaluate','classify']);p.add_argument('--project');p.add_argument('--input',required=True);p.add_argument('--data',required=True);p.add_argument('--output',required=True);p.add_argument('--status',required=True);p.add_argument('--recipe');p.add_argument('--stop-file',required=True);p.add_argument('--budget',type=float,default=2);a=p.parse_args()
    lock_path=Path(a.data)/'sol'/'worker.lock';lock_path.parent.mkdir(parents=True,exist_ok=True)
    with lock_path.open('w') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:atomic_json(a.status,dict(state='error',message='A project job is already running.'));return
        try:
            if a.command=='train':build_recipe(read_json(a.project,{}),read_json(a.input,[]),a.data,a.output,a.status);return
            key=os.environ.get('OPENAI_API_KEY') or (KEY_PATH.read_text().strip() if KEY_PATH.exists() else '')
            if not key.startswith('sk-') or '...' in key or '…' in key:raise ValueError('Configure your own full API secret key first.')
            if not 0<a.budget<=100:raise ValueError('Choose a cost stop greater than $0 and at most $100.')
            recipe=read_json(a.recipe,None)
            if not recipe:raise ValueError('Train a classifier first.')
            if a.command=='evaluate':evaluate(recipe,a.data,a.output,a.status,a.stop_file,a.budget,key)
            else:Worker(a.data,a.status,a.stop_file,a.budget,key=key,recipe=recipe).run(read_json(a.input,[]),a.output)
        except Exception as e:
            # Never include server response bodies or credentials in status output.
            safe=str(e) if isinstance(e,ValueError) else 'Project job failed. Check that images are available and the classifier is valid.'
            atomic_json(a.status,dict(state='error',message=safe))

if __name__=='__main__':main()
