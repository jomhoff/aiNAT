import json, os, stat, subprocess, tempfile, unittest
from pathlib import Path
from PIL import Image
from project_model import build_recipe, recipe_payload, parse_recipe_response, calibrate, apply_policy, evaluate, aggregate, validate_project
from sol_classifier import Worker, atomic_json

class ProjectModels(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.data=Path(self.tmp.name);self.status=self.data/'status.json'
        self.project=dict(id='test-project',name='Test',species={'name':'Example species'},task='Classify whether a visible patch has spots.',categories=[{'key':'spotted','label':'Spotted','description':'Clear spots'},{'key':'plain','label':'Plain','description':'Visible patch without spots'}])
        self.records=[]
        for label,offset in [('spotted',0),('plain',100)]:
            for i in range(20):
                id=str(offset+i);path=self.data/f'{id}.png';Image.new('RGB',(24,24),(offset+i,i*5,100)).save(path)
                self.records.append({'id':id,'label':label,'photos':[{'id':id,'image_path':str(path)}]})
        self.out=self.data/'run';self.recipe=build_recipe(self.project,self.records,self.data,self.out,self.status)
    def tearDown(self):self.tmp.cleanup()
    def response(self,label,score=98,visible=True):
        return {'id':'test','model':'gpt-6.1-sol','status':'completed','usage':{'input_tokens':100,'output_tokens':40},'output':[{'type':'message','content':[{'type':'output_text','text':json.dumps({'morph':label,'reason':'Visible pattern','confidence':score,'feature_visible':visible})}]}]}
    def test_splits_and_payload_hide_evaluation_labels(self):
        splits=self.recipe['splits'];ids={k:{r['id'] for r in v} for k,v in splits.items()}
        self.assertFalse(ids['teaching']&ids['calibration']);self.assertFalse(ids['teaching']&ids['test']);self.assertFalse(ids['test']&ids['calibration'])
        teaching_ids={e['observation_id'] for e in self.recipe['examples']};self.assertTrue(teaching_ids<=ids['teaching'])
        payload=recipe_payload(self.recipe,self.records[0]['photos'][0]['image_path'])
        self.assertFalse(payload['store']);self.assertEqual(payload['text']['format']['schema']['properties']['morph']['enum'],['spotted','plain','cant_tell'])
        self.assertNotIn('splits',payload);self.assertEqual(len(self.recipe['examples']),4)
    def test_confidence_and_visibility_validation(self):
        a=parse_recipe_response(self.response('plain',99,False),self.recipe);self.assertEqual(a['morph'],'cant_tell')
        with self.assertRaises(ValueError):parse_recipe_response(self.response('invalid'),self.recipe)
        with self.assertRaises(ValueError):parse_recipe_response(self.response('plain',101),self.recipe)
        label,_,_=aggregate([{'morph':'plain','confidence':99,'feature_visible':True,'reason':'no spots'},{'morph':'spotted','confidence':99,'feature_visible':True,'reason':'spots'}],self.recipe)
        self.assertEqual(label,'cant_tell')
    def test_thresholds_require_evidence_and_do_not_use_test(self):
        rows=[dict(raw_label='plain',truth='plain',confidence=95,feature_visible=True) for _ in range(10)]+[dict(raw_label='plain',truth='spotted',confidence=70,feature_visible=True)]
        p=calibrate(rows,['plain','spotted']);self.assertEqual(p['thresholds']['plain'],71);self.assertIsNone(p['thresholds']['spotted'])
        self.assertEqual(apply_policy(dict(raw_label='plain',confidence=70,feature_visible=True),p),'cant_tell')
        self.assertIsNone(calibrate(rows[:9],['plain'])['thresholds']['plain'])
    def test_duplicate_images_stay_in_same_split(self):
        duplicate=dict(self.records[0],id='duplicate-observation');records=self.records+[duplicate]
        r=build_recipe(self.project,records,self.data,self.data/'other',self.status)
        assignments={row['id']:split for split,rows in r['splits'].items() for row in rows}
        self.assertEqual(assignments[duplicate['id']],assignments[self.records[0]['id']])
    def test_project_fingerprint_and_cache_separation(self):
        p=dict(self.project,task='Classify another visual trait');r=build_recipe(p,self.records,self.data,self.data/'other',self.status)
        self.assertNotEqual(r['config_id'],self.recipe['config_id'])
        calls=[]
        def requester(image):calls.append(str(image));return self.response('plain')
        row=dict(self.records[0]);row.pop('label')
        Worker(self.data,self.status,self.data/'stop',1,requester=requester,recipe=self.recipe).run([row],self.data/'p.json')
        Worker(self.data,self.status,self.data/'stop',1,requester=requester,recipe=r).run([row],self.data/'p.json')
        self.assertEqual(len(calls),2)
    def test_evaluation_uses_only_heldout_and_is_resumable(self):
        seen=[]
        truths={str(Path(r['photos'][0]['image_path']).resolve()):r['label'] for r in self.records}
        def requester(image):seen.append(str(image));return self.response(truths[str(image)])
        evaluate(self.recipe,self.data,self.out,self.status,self.data/'stop',2,'test',requester)
        s=json.loads((self.out/'evaluation_summary.json').read_text());self.assertEqual(s['raw_test']['wrong'],0)
        # Four calibration cases per class cannot establish a ten-case policy.
        self.assertEqual(s['test']['accepted'],0)
        before=len(seen);evaluate(self.recipe,self.data,self.out,self.status,self.data/'stop',2,'test',requester);self.assertEqual(len(seen),before)
        teaching={r['photos'][0]['image_path'] for r in self.recipe['splits']['teaching']};self.assertFalse(teaching&set(seen))
    def test_own_key_saved_outside_project_with_private_permissions(self):
        destination=self.data/'private'/'api-key';env=dict(os.environ,SPECIES_VISION_KEY_FILE=str(destination))
        result=subprocess.run([os.sys.executable,'openai_key_setup.py','--stdin'],input='sk-test-not-a-real-key',text=True,capture_output=True,env=env)
        self.assertEqual(result.returncode,0);self.assertNotIn('sk-test',result.stdout);self.assertEqual(stat.S_IMODE(destination.stat().st_mode),0o600)

if __name__=='__main__':unittest.main()
