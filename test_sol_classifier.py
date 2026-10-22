import json
import tempfile
import unittest
from pathlib import Path
from PIL import Image
from sol_classifier import Worker, CONFIG_ID, atomic_json, combine_photos, import_evaluation_cache, cache_path
import hashlib


def response(morph='red_backed'):
    return {'id':'response-test','model':'gpt-6.1-sol','status':'completed','usage':{'input_tokens':100,'output_tokens':20},'output':[{'type':'message','content':[{'type':'output_text','text':json.dumps({'morph':morph,'reason':'Visible dorsal pattern.'})}]}]}


class SolWorkflow(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        (self.root/'annotations'/'images').mkdir(parents=True)
        for i in range(1,9): Image.new('RGB',(30,30),'gray').save(self.root/'annotations'/'images'/f'{i}.png')
        self.calls=0
    def tearDown(self):self.tmp.cleanup()
    def worker(self,requester=None,budget=1):
        def request(image):self.calls+=1;return response()
        return Worker(self.root,self.root/'status.json',self.root/'stop',budget,requester=requester or request)
    def row(self,id='101',photos=('1',)):
        return {'id':id,'photos':[{'id':i,'url':'https://unused.invalid/'} for i in photos]}
    def test_cache_prevents_duplicate_api_charges(self):
        output=self.root/'predictions.json';w=self.worker();w.run([self.row()],output)
        self.assertEqual(self.calls,1)
        result=json.loads(output.read_text())[0];self.assertEqual(result['ai_morph'],'red_backed');self.assertEqual(result['config_id'],CONFIG_ID)
        w2=self.worker();s=w2.run([self.row()],output)
        self.assertEqual(self.calls,1);self.assertEqual(s['estimated_cost_usd'],0);self.assertEqual(s['cached_photos'],1)
    def test_all_photos_must_agree(self):
        self.assertEqual(combine_photos([{'morph':'red_backed','reason':'stripe'},{'morph':'lead_backed','reason':'no stripe'}])[0],'cant_tell')
        self.assertEqual(combine_photos([{'morph':'lead_backed','reason':'no stripe'},{'morph':'cant_tell','reason':'blur'}])[0],'cant_tell')
        w=self.worker(lambda image:response('red_backed' if image.stem=='1' else 'lead_backed'))
        w.run([self.row(photos=('1','2'))],self.root/'p.json')
        self.assertEqual(json.loads((self.root/'p.json').read_text())[0]['ai_morph'],'cant_tell')
    def test_stop_retains_existing_answers(self):
        out=self.root/'p.json';atomic_json(out,[{'id':'old','ai_morph':'lead_backed'}]);(self.root/'stop').touch()
        s=self.worker().run([self.row()],out)
        self.assertEqual(self.calls,0);self.assertEqual(s['state'],'stopped');self.assertEqual(len(json.loads(out.read_text())),1)
    def test_api_error_stops_without_retry_or_false_result(self):
        def fail(image):self.calls+=1;raise RuntimeError('HTTP 401')
        s=self.worker(fail).run([self.row()],self.root/'p.json')
        self.assertEqual(self.calls,1);self.assertEqual(s['state'],'error');self.assertFalse((self.root/'p.json').exists())
    def test_unparseable_paid_response_is_cached(self):
        def bad(image):self.calls+=1;r=response();r['output']=[];return r
        w=self.worker(bad);s=w.run([self.row()],self.root/'p.json')
        self.assertEqual(s['state'],'complete');self.assertEqual(json.loads((self.root/'p.json').read_text())[0]['ai_morph'],'cant_tell')
        self.worker(bad).run([self.row()],self.root/'p.json');self.assertEqual(self.calls,1)
    def test_budget_stops_new_requests(self):
        s=self.worker(budget=.00001).run([self.row(str(100+i),(str(i),)) for i in range(1,9)],self.root/'p.json')
        self.assertTrue(1<=self.calls<=4);self.assertEqual(s['state'],'stopped');self.assertGreater(s['estimated_cost_usd'],0)
    def test_partial_observation_resumes_from_photo_cache(self):
        def stop_after_first(image):
            self.calls+=1
            (self.root/'stop').touch()
            return response()
        out=self.root/'p.json'
        state=self.worker(stop_after_first).run([self.row(photos=('1','2'))],out)
        self.assertEqual(state['state'],'stopped');self.assertFalse(out.exists())
        (self.root/'stop').unlink()
        state=self.worker().run([self.row(photos=('1','2'))],out)
        self.assertEqual(state['state'],'complete');self.assertEqual(self.calls,2)
        self.assertEqual(state['cached_photos'],1)

    def test_import_paid_results_without_reference_labels(self):
        root=self.root/'sol-large-test-20261022';root.mkdir();image=self.root/'annotations'/'images'/'1.png';digest=hashlib.sha256(image.read_bytes()).hexdigest()
        atomic_json(root/'manifest.json',[{'code':'L001','photo_id':'1','image_path':str(image),'image_sha256':digest}])
        atomic_json(root/'answers.json',[{'code':'L001','morph':'lead_backed','reason':'No stripe','actual_model':'gpt-6.1-sol','response_id':'test','estimated_cost_usd':.1,'truth_morph':'red_backed'}])
        self.assertEqual(import_evaluation_cache(self.root),1)
        saved=json.loads(cache_path(self.root,'1',digest).read_text());self.assertNotIn('truth_morph',saved)
        self.worker().run([self.row()],self.root/'p.json');self.assertEqual(self.calls,0)

if __name__=='__main__':unittest.main()
