"""Twenty separate, label-hidden Sol Responses API image requests; resumable and cost logged."""
import argparse,base64,json,os,urllib.request,urllib.error
from pathlib import Path
from openai_key_setup import KEY_PATH
MODEL='gpt-6.1-sol'
PROMPT='''Classify the visible dorsal color morph of the eastern red-backed salamander in this photograph. Return red_backed if a distinct red, orange, tan or brown mid-dorsal stripe contrasts with darker flanks. Return lead_backed only if the dorsal surface is clearly visible and lacks a distinct stripe. Return cant_tell if blur, soil, glare, pose, obstruction, multiple animals with conflicting morphs, or uncertainty prevents a reliable judgment. Distinguish pigment from reflections and background debris. Prioritize avoiding incorrect morph assignments over coverage. Judge the image alone; never infer morph from location or presumed frequencies. Give one brief visual reason, without claiming a calibrated confidence probability.'''
SCHEMA={'type':'object','properties':{'morph':{'type':'string','enum':['red_backed','lead_backed','cant_tell']},'reason':{'type':'string'}},'required':['morph','reason'],'additionalProperties':False}

def payload(image):
    return dict(model=MODEL,store=False,reasoning={'effort':'low'},max_output_tokens=2000,
      input=[{'role':'user','content':[{'type':'input_text','text':PROMPT},{'type':'input_image','image_url':'data:image/png;base64,'+base64.b64encode(Path(image).read_bytes()).decode(),'detail':'high'}]}],
      text={'format':{'type':'json_schema','name':'salamander_morph','strict':True,'schema':SCHEMA}})

def parse_response(response):
    if response.get('status')!='completed':return dict(morph='cant_tell',reason='API response incomplete or refused',api_status=response.get('status'))
    text=''.join(c.get('text','') for o in response.get('output',[]) if o.get('type')=='message' for c in o.get('content',[]) if c.get('type')=='output_text')
    answer=json.loads(text)
    if answer.get('morph') not in SCHEMA['properties']['morph']['enum']:raise ValueError('Unexpected morph response')
    return answer

def atomic(path,value):
    tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(value,indent=2));os.replace(tmp,path)

def run(root,limit):
    key=os.environ.get('OPENAI_API_KEY') or (KEY_PATH.read_text().strip() if KEY_PATH.exists() else None)
    if not key:raise SystemExit('API key missing. Double-click Configure OpenAI.command first. No requests were made.')
    pilot=Path(root)/'direct-vision-pilot';out=Path(root)/'sol-api-pilot';out.mkdir(exist_ok=True)
    answers_path=out/'answers.json';answers=json.loads(answers_path.read_text()) if answers_path.exists() else []
    atomic(out/'protocol.json',dict(model=MODEL,prompt=PROMPT,image_detail='high',reasoning_effort='low',max_output_tokens=2000,limit=limit,notes='Separate independent API requests; no labels, previous conversation, or previous responses sent. Prices estimated at standard $2/M input, $0.10/M cached input, $10/M output; all output tokens including reasoning count.'))
    total=sum(x['estimated_cost_usd'] for x in answers)
    for i in range(1,limit+1):
        code=f'P{i:02d}'
        if any(x['code']==code for x in answers):continue
        if total>=1:raise SystemExit('Stopped after recorded estimated usage reached $1. No further request sent. This check is not a hard billing cap.')
        request=urllib.request.Request('https://api.openai.com/v1/responses',data=json.dumps(payload(pilot/f'{code}.png')).encode(),headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'},method='POST')
        try:
            with urllib.request.urlopen(request,timeout=180) as response:r=json.load(response)
        except urllib.error.HTTPError as e:
            # Do not echo credentials, request payloads, or raw server bodies.
            raise SystemExit(f'API request stopped: HTTP {e.code}. Check API key, model access, and available billing credits. No automatic retry.')
        usage=r.get('usage',{});cached=usage.get('input_tokens_details',{}).get('cached_tokens',0)
        cost=((usage.get('input_tokens',0)-cached)*2+cached*.1+usage.get('output_tokens',0)*10)/1e6
        # Save the billed response before parsing so malformed replies are not resent on resume.
        row=dict(code=code,response_id=r.get('id'),actual_model=r.get('model'),usage=usage,estimated_cost_usd=cost,morph='cant_tell',reason='Response parsing failed')
        try:row.update(parse_response(r))
        except (ValueError,KeyError):pass
        answers.append(row);total+=cost;atomic(answers_path,answers)
        print(f'{code}: saved; running estimated API cost ${total:.4f}',flush=True)
    # Only access human labels after all requested predictions have been saved.
    truth={r['code']:r for r in json.loads((pilot/'scoring-key.json').read_text())}
    scored=[dict(**a,truth_morph=truth[a['code']]['truth_morph']) for a in answers]
    accepted=[a for a in scored if a['morph']!='cant_tell']
    correct=sum(a['morph']==a['truth_morph'] for a in accepted)
    summary=dict(model=MODEL,n=len(scored),accepted=len(accepted),correct=correct,wrong=len(accepted)-correct,cant_tell=len(scored)-len(accepted),accepted_accuracy=correct/len(accepted) if accepted else None,estimated_cost_usd=total,
       limitation='Same 20-photo validation pilot already seen by this conversation; separate API calls do not receive that context, but this remains a small development sample.')
    atomic(out/'scored.json',scored);atomic(out/'summary.json',summary);print(json.dumps(summary,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--run');p.add_argument('--limit',type=int,default=20);args=p.parse_args()
    root=args.run or json.loads(Path('data/vision_model.json').read_text())['run_dir']
    if not 1<=args.limit<=20:raise SystemExit('Pilot limit must be between 1 and 20.')
    run(root,args.limit)
