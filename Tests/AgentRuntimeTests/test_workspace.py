import base64, pathlib, sys, tempfile, unittest, os
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[2]/'Sources/TravelCatApp/Resources/AgentRuntime'))
import workspace_io

class WorkspaceTests(unittest.TestCase):
    def test_flat_selected_import_and_export(self):
        with tempfile.TemporaryDirectory() as root:
            files=[{'name':'input.txt','base64':base64.b64encode(b'hello').decode()}]
            self.assertEqual(workspace_io.perform({'method':'import','files':files},root),{'imported':1})
            self.assertEqual(workspace_io.perform({'method':'artifacts'},root),{'files':[{'path':'input.txt','size':5}]})
            self.assertEqual(workspace_io.perform({'method':'export','path':'input.txt'},root),files[0])
    def test_unsafe_inputs_and_duplicates_rejected(self):
        for name in ['../x','/tmp/x','.env','key.txt','api_key.json','secret.txt','sub/file','a\\b','id_rsa','token.txt','x.pem']:
            with self.assertRaises(ValueError):workspace_io.validate_files([{'name':name,'base64':'YQ=='}])
        with self.assertRaises(ValueError):workspace_io.validate_files([{'name':'x','base64':'YQ=='}]*2)
        with self.assertRaises(ValueError):workspace_io.validate_files([{'name':'large','base64':base64.b64encode(b'x'*(1024*1024+1)).decode()}])
    def test_symlink_and_traversal_exports_denied(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
            pathlib.Path(outside,'other').write_text('private')
            pathlib.Path(root,'link').symlink_to(pathlib.Path(outside,'other'))
            pathlib.Path(root,'dir').symlink_to(outside,target_is_directory=True)
            for path in ['../other','/etc/passwd','link','dir/other']:
                with self.assertRaises((ValueError,OSError)):workspace_io.perform({'method':'export','path':path},root)
            self.assertEqual(workspace_io.perform({'method':'artifacts'},root),{'files':[]})
    def test_root_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path=pathlib.Path(root,'alias');path.symlink_to(root,target_is_directory=True)
            with self.assertRaises(OSError):workspace_io.perform({'method':'artifacts'},str(path))
    def test_export_size_limit_and_hidden_files(self):
        with tempfile.TemporaryDirectory() as root:
            pathlib.Path(root,'large').write_bytes(b'x'*(4*1024*1024+1))
            pathlib.Path(root,'.env').write_text('secret')
            with self.assertRaises(ValueError):workspace_io.perform({'method':'export','path':'large'},root)
            self.assertEqual(workspace_io.perform({'method':'artifacts'},root),{'files':[]})
