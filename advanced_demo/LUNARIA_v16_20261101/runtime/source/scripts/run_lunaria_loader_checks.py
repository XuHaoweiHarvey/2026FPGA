"""Offline tests: real ELF, complete 600-chunk upload, fault paths, and UI."""
from pathlib import Path
import os
from contextlib import nullcontext
import json
import hashlib
import re
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from game_debug_bridge import APB, DebugBridge, ElfImage, RAM_END, PRESENTATION_FIELDS, RUNTIME_FIELDS
from lunaria_debug_bridge import (LunariaBridge, DEFAULT_ELF, DEFAULT_ASSETS,
                                 MAGIC, WAIT, READY, FAULT, FIELDS, WORDS, fnv_words, read_assets,
                                 SETTINGS_FIELDS, SETTINGS_MAGIC)
from lunaria_debug_bridge import DDR_FIELDS, ddr_interval
sys.path.insert(0,str(ROOT/'scripts'))
from run_game_debug_checks import FakeBridge


class FakeUpload(LunariaBridge):
    def __init__(self):
        super().__init__()
        self.cpu = 'running'
        self.mail = dict.fromkeys(FIELDS,0)
        self.mail.update(magic=MAGIC,version=1,state=WAIT)
        self.calls, self.writes = [], []
        self.data = b''
        self.corrupt_ack = False
        self.fail_commit = False
        self.hash = 2166136261
        self.blocks = 0

    def read_words(self,address,count):
        if address == self.upload_address:
            return [self.mail[key] for key in FIELDS[:count]]
        raise AssertionError(hex(address))

    def rpc(self,script):
        self.calls.append(script)
        if 'curstate' in script: return self.cpu
        if script == 'halt; wait_halt 2000': self.cpu = 'halted'
        elif script == 'resume':
            self.cpu = 'running'
            if self.mail['sequence'] != self.mail['ack'] and self.data:
                self.blocks += 1
                data = self.data
                assert self.mail['count'] == len(data)//4
                assert fnv_words(data) == self.mail['expected_hash']
                for (word,) in struct.iter_unpack('<I',data):
                    self.hash = ((self.hash^word)*16777619)&0xffffffff
                window = self.mail['window']
                name = 'received_atlas' if window else 'received_background'
                assert self.mail['offset'] == self.mail[name]
                self.mail[name] += len(data)//4
                self.mail['actual_hash'] = fnv_words(data) ^ int(self.corrupt_ack)
                if self.mail[name] == WORDS:
                    self.mail['atlas_hash' if window else 'background_hash'] = self.hash
                    self.hash = 2166136261
                    if window: self.mail['state'] = READY
                self.mail['ack'] = self.mail['sequence']
        elif script.startswith('load_image '):
            match = re.fullmatch(r'load_image "(.+)" (0x[0-9a-f]+) bin',script)
            assert match and int(match[2],0) == self.chunk_address
            self.data = Path(match[1]).read_bytes()
        elif script.startswith('mww '):
            _,address,value = script.split()
            address,value = int(address,0),int(value,0)
            assert self.upload_address <= address < self.upload_address+4*len(FIELDS)
            key = FIELDS[(address-self.upload_address)//4]
            if self.fail_commit and key == 'sequence': raise OSError('injected JTAG failure')
            self.mail[key] = value
            self.writes.append((key,value))
        else: raise AssertionError(script)
        return ''


class Checks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.assets = read_assets(DEFAULT_ASSETS)

    def test_real_elf_and_assets(self):
        image = ElfImage(DEFAULT_ELF)
        bridge = LunariaBridge()
        self.assertEqual(bridge.asset_hashes,[h for _,h in self.assets])
        self.assertEqual(image.symbol_u32('g_game_required_caps'),0x10E00)
        self.assertEqual(image.symbol_u32('g_game_beam_compatible'),0x10000)
        self.assertEqual(image.symbol_u32('g_game_scale2_compatible'),0x4000)
        self.assertEqual(image.symbol_u32('g_game_alpha_hardware_compatible'),0x3000)
        self.assertEqual(image.symbol_u32('g_lunaria_v12_compatible'),0x8000)
        self.assertLessEqual(image.symbol('_sp'),RAM_END)
        self.assertEqual(image.symbols['g_lunaria_chunk'][1],4096)

    def test_v12_hardware_pairing_and_feature_guard(self):
        for version,caps in ((0xD0000,0x1FFFB),(0xE0000,0x3FFFB)):
            fake=FakeBridge(DEFAULT_ELF)
            fake.memory[APB+4]=version;fake.memory[APB+0x40]=caps
            fake.load()
            self.assertIn(f'resume {fake.image.entry:#x}',fake.calls)
        for cap in (0x7FFB,0xBFFB,0xFFFB,0x1DFFB):
            fake=FakeBridge(DEFAULT_ELF)
            fake.memory[APB+4]=0xD0000;fake.memory[APB+0x40]=cap
            with self.assertRaises(RuntimeError):fake.load()
            self.assertFalse(any(c.startswith('load_image') for c in fake.calls))
        fake=FakeBridge(DEFAULT_ELF)
        fake.memory[APB+4]=0xD0000;fake.memory[APB+0x40]=0x1FFFB
        fake.image.symbols.pop('g_lunaria_available')
        with self.assertRaisesRegex(RuntimeError,'LUNARIA'):fake.load()

    def test_v14_requires_new_startup_marker_and_exact_capabilities(self):
        for caps,old in ((0x1fffb,False),(0x2fffb,False),(0x37ffb,False),(0x3fffb,True)):
            fake=FakeBridge(DEFAULT_ELF)
            fake.memory[APB+4]=0xE0000;fake.memory[APB+0x40]=caps
            if old:fake.image.symbols.pop('g_lunaria_v14_compatible')
            with self.assertRaises(RuntimeError):fake.load()
            self.assertFalse(any(c.startswith('load_image') for c in fake.calls))

    def test_v16_pairing_and_snapshot(self):
        fake=FakeBridge(DEFAULT_ELF)
        fake.memory[APB+4]=0x100000;fake.memory[APB+0x40]=0xffffb
        fake.memory[APB+0xe8]=29
        for i in range(29):fake.memory[APB+0x100+4*i]=i
        self.assertEqual(LunariaBridge.capture_ddr(fake),list(range(29)))
        fake.load()
        self.assertTrue(any(c.startswith('load_image') for c in fake.calls))
        for caps,old in ((0x7fffb,False),(0xffffb,True)):
            fake=FakeBridge(DEFAULT_ELF)
            fake.memory[APB+4]=0x100000;fake.memory[APB+0x40]=caps
            if old:fake.image.symbols.pop('g_lunaria_v16_compatible')
            with self.assertRaises(RuntimeError):fake.load()
            self.assertFalse(any(c.startswith('load_image') for c in fake.calls))

    def test_v15_pairing_and_snapshot(self):
        fake=FakeBridge(DEFAULT_ELF)
        fake.memory[APB+4]=0xF0000;fake.memory[APB+0x40]=0x7fffb
        fake.memory[APB+0xe8]=29
        for i in range(29):fake.memory[APB+0x100+4*i]=i
        self.assertEqual(LunariaBridge.capture_ddr(fake),list(range(29)))
        fake.image.symbols.pop('g_lunaria_v15_compatible')
        with self.assertRaises(RuntimeError):fake.load()
        self.assertFalse(any(c.startswith('load_image') for c in fake.calls))
        fake=FakeBridge(DEFAULT_ELF)
        fake.memory[APB+4]=0xF0000;fake.memory[APB+0x40]=0x3fffb
        with self.assertRaises(RuntimeError):fake.load()
        self.assertFalse(any(c.startswith('load_image') for c in fake.calls))
        report=ddr_interval([0]*29,[500000000]+[1]*28)
        self.assertEqual(report['counters']['target_bursts'],1)
        with self.assertRaises(ValueError):ddr_interval([0]*21,[0]*29)

    def test_ddr_counter_rates_wrap_and_no_frame_state_bandwidth(self):
        before=[0xfffffff0]*21
        delta=[500000000,30,100000000,1000000,2000000,2000000,75,25,
               50000000,100000000,25000000,0,25000000,2000000,0,100000000,300,500,10,0,0]
        after=[(a+d)&0xffffffff for a,d in zip(before,delta)]
        report=ddr_interval(before,after)
        self.assertEqual(report['seconds'],5)
        self.assertEqual(report['cache_hit_percent'],75)
        self.assertEqual(report['alpha_MB_per_second']['source_beats'],3.2)
        self.assertEqual(report['wall_time_percent']['read_data_wait'],20)
        self.assertNotIn('reader_frame_beats',report['alpha_MB_per_second'])
        with self.assertRaises(ValueError):ddr_interval(before,before)

    def test_ddr_capture_is_version_guarded_and_snapshot_only(self):
        fake=FakeBridge(DEFAULT_ELF)
        fake.memory[APB+4]=0xD0000;fake.memory[APB+0x40]=0x1fffb
        with self.assertRaisesRegex(RuntimeError,'v16'):LunariaBridge.capture_ddr(fake)
        self.assertFalse(fake.writes)
        fake.memory[APB+4]=0xE0000;fake.memory[APB+0x40]=0x3fffb
        fake.memory[APB+0xe8]=21
        for i in range(21):fake.memory[APB+0x100+4*i]=i
        self.assertEqual(LunariaBridge.capture_ddr(fake),list(range(21)))
        self.assertEqual(fake.cpu,'running')
        self.assertEqual(fake.writes,[(APB+0xe8,1)])

    def test_beam_firmware_rejects_v10_v11_v12_before_loading(self):
        for version,caps in ((0xA0000,0x3FFB),(0xB0000,0x7FFB),(0xC0000,0xFFFB)):
            fake=FakeBridge(DEFAULT_ELF)
            fake.memory[APB+4]=version;fake.memory[APB+0x40]=caps
            with self.assertRaisesRegex(RuntimeError,'v13'): fake.load()
            self.assertFalse(any(c.startswith('load_image') for c in fake.calls))

    def test_v12_old_firmware_rejected_before_ram_write(self):
        fake = FakeBridge(DEFAULT_ELF)
        fake.memory[APB+4] = 0xC0000; fake.memory[APB+0x40] = 0xFFFB
        fake.image.symbols.pop('g_lunaria_v12_compatible')
        with self.assertRaisesRegex(RuntimeError,'启动兼容修复'): fake.load()
        self.assertFalse(fake.writes)
        self.assertFalse(any(c.startswith('load_image') for c in fake.calls))

    def test_boot_fault_before_upload_magic_does_not_timeout(self):
        for magic,version in ((0,0),(MAGIC,1)):
            fake = FakeUpload()
            fake.mail.update(magic=magic,version=version,state=FAULT,error=0xE000)
            with patch('lunaria_debug_bridge.time.sleep') as sleep:
                with self.assertRaisesRegex(RuntimeError,'0xE000.*v13'):
                    fake.upload_assets(self.assets)
                sleep.assert_not_called()
            self.assertFalse(fake.writes)
            self.assertEqual(fake.cpu,'running')

    def test_code_mismatch_collects_unverified_readonly_evidence(self):
        class Probe(FakeBridge,LunariaBridge):
            _verified_snapshot=LunariaBridge._verified_snapshot
        fake=Probe(DEFAULT_ELF)
        address,data=fake.image.code[0]
        fake.memory[address]=0
        fake.memory[APB+0xD4]=4
        with self.assertRaisesRegex(RuntimeError,'first_address=.*raw_diagnostics=') as caught:
            LunariaBridge.snapshot(fake,verify=True)
        self.assertIn('"code_verified": false',str(caught.exception))
        self.assertIn('"0xd4": 4',str(caught.exception))
        self.assertFalse(fake.writes)
        self.assertFalse(fake.matched)
        self.assertEqual(fake.cpu,'running')
        self.assertFalse(any(c.startswith('load_image') for c in fake.calls))

    def test_ddr_failure_retains_block_details(self):
        fake=FakeUpload()
        fake.mail.update(state=FAULT,error=0xEA05,window=1,offset=2048,count=1024,sequence=3)
        with self.assertRaisesRegex(RuntimeError,'0xEA05.*"offset": 2048'):
            fake._wait(lambda status:False)
        self.assertFalse(fake.writes)
        self.assertEqual(fake.cpu,'running')

    def test_full_upload_and_sequence_last(self):
        fake = FakeUpload()
        fake.upload_assets(self.assets)
        self.assertEqual(fake.blocks,600)
        self.assertEqual(fake.mail['state'],READY)
        self.assertEqual(fake.mail['ack'],600)
        self.assertEqual([fake.mail['background_hash'],fake.mail['atlas_hash']],fake.asset_hashes)
        self.assertEqual(fake.cpu,'running')
        self.assertEqual([key for key,_ in fake.writes[:5]],['window','offset','count','expected_hash','sequence'])
        fake.upload_assets(self.assets)
        self.assertEqual(fake.blocks,600) # cached verification does not rewrite assets

    def test_invalid_ranges_and_wrong_window_never_write(self):
        for window,offset,data in ((2,0,b'1234'),(0,-1,b'1234'),(0,WORDS,b'1234'),
                                   (0,0,b'123'),(0,0,b''),(0,0,b'0'*4100),(1,0,b'1234')):
            fake = FakeUpload()
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises((ValueError,RuntimeError)):
                    fake._put(window,offset,data,1,Path(directory)/'chunk.bin')
            self.assertFalse(fake.writes)
            self.assertEqual(fake.cpu,'running')

    def test_ack_hash_failure_and_write_failure_restore_cpu(self):
        for mode in ('corrupt_ack','fail_commit'):
            fake = FakeUpload(); setattr(fake,mode,True)
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises((RuntimeError,OSError)):
                    fake._put(0,0,b'1234',1,Path(directory)/'chunk.bin')
            self.assertEqual(fake.cpu,'running')
            self.assertEqual(fake.blocks,1 if mode == 'corrupt_ack' else 0)

    def test_pending_sequence_and_halted_cpu_never_write(self):
        fake = FakeUpload(); fake.mail['sequence'] = 1
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                fake._put(0,0,b'1234',1,Path(directory)/'chunk.bin')
        self.assertFalse(fake.writes)
        fake = FakeUpload(); fake.cpu = 'halted'
        with self.assertRaises(RuntimeError): fake.upload_assets(self.assets)
        self.assertEqual(fake.cpu,'halted')

    def test_fault_timeout_and_interrupted_upload(self):
        fake = FakeUpload(); fake.mail.update(state=FAULT,error=0xEA08)
        with self.assertRaisesRegex(RuntimeError,'EA08'): fake.upload_assets(self.assets)
        fake = FakeUpload()
        with self.assertRaises(TimeoutError): fake._wait(lambda s: False,seconds=0)
        fake.mail['ack'] = 1
        with self.assertRaisesRegex(RuntimeError,'中断上传'): fake.upload_assets(self.assets)
        self.assertFalse(fake.writes)

    def test_file_validation_before_loading(self):
        bridge = LunariaBridge()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'assets.json'
            manifest = json.loads(DEFAULT_ASSETS.read_text(encoding='utf8'))
            manifest['assets']['background']['file'] = '../background.argb'
            path.write_text(json.dumps(manifest),encoding='utf8')
            bridge.assets = path
            with patch.object(DebugBridge,'load') as load:
                with self.assertRaises(ValueError): bridge.load()
                load.assert_not_called()
        with patch('lunaria_debug_bridge.read_assets',return_value=[(b'',0),(b'',0)]), patch.object(DebugBridge,'load') as load:
            with self.assertRaises(ValueError): bridge.load()
            load.assert_not_called()

    def test_lunaria_measurement_without_fake_stress_flags(self):
        fake = FakeBridge(DEFAULT_ELF)
        for start,offset,size in fake.image.load_segments:
            for name in ('g_lunaria_available','g_game_showcase_available'):
                address = fake.image.symbol(name,4)
                if start <= address < start+size: fake.memory[address] = fake.image.symbol_u32(name)
        fake.set_status(invincible_mode=1,enemy_limit=1)
        addr = fake.image.symbol('g_game_presentation',4*len(PRESENTATION_FIELDS))
        fake.memory[addr+4*PRESENTATION_FIELDS.index('state')] = 2
        self.assertEqual(fake.command(7),1)
        runtime = fake.image.symbol('g_game_runtime',4*len(RUNTIME_FIELDS))
        self.assertFalse(fake.memory.get(runtime+4*RUNTIME_FIELDS.index('stress_mode'),0))
        fake.set_status(acknowledged_sequence=1)
        before = len(fake.writes)
        with self.assertRaises(RuntimeError): fake.command(8)
        self.assertEqual(len(fake.writes),before)
        fake.memory[addr+4*PRESENTATION_FIELDS.index('state')] = 0
        with self.assertRaises(RuntimeError): fake.command(7)

    def test_optional_metrics_extension_and_partial_snapshot(self):
        bridge = LunariaBridge()
        address = bridge.image.symbol('g_lunaria_metrics',36)
        timing_address = bridge.image.symbol('g_lunaria_timing',28)
        values = [0x4c4e4d31,1,2,5990,190,230,204,247,3]
        reads = []
        def read(addr,count):
            reads.append((addr,count))
            if addr == timing_address:
                return [0x4c4e5431,1,2,100,200,300,400]
            if addr != address:
                return [SETTINGS_MAGIC,1,0,0,0,256,0,256,0,64,4096]
            return values[:]
        with patch.object(DebugBridge,'snapshot',return_value={'fps_x100':5990}), \
             patch.object(bridge,'halted',side_effect=lambda:nullcontext(True)), \
             patch.object(bridge,'read_words',side_effect=read):
            result = bridge.snapshot()
            self.assertEqual(result['lunaria_metrics']['peak_elements'],247)
            self.assertEqual(result['lunaria_metrics']['bullets'],190)
            self.assertEqual(result['lunaria_metrics']['fps_x100'],5990)
            self.assertFalse(result['partial_lunaria_metrics'])
            self.assertIn((address,9),reads)
            self.assertEqual(result['lunaria_timing']['swap_us'],400)
            self.assertEqual(result['lunaria_settings']['capacity'],4096)
            values[2]=3
            self.assertTrue(bridge.snapshot()['partial_lunaria_metrics'])

    def settings_fake(self):
        fake = FakeBridge(DEFAULT_ELF)
        address = fake.image.symbol('g_lunaria_settings',4*len(SETTINGS_FIELDS))
        for i in range(len(SETTINGS_FIELDS)):
            fake.memory[address+4*i] = fake.image.symbol_u32('g_lunaria_settings',i)
        return fake,address

    def test_settings_sequence_last_and_wrap(self):
        fake,address = self.settings_fake()
        sequence = LunariaBridge.configure(fake,4096,True,(0,900,1,1,255))
        self.assertEqual(sequence,1)
        self.assertEqual(fake.writes[-1],(address+8,1))
        self.assertEqual(fake.writes[:2],[(address+20,4096),(address+24,1)])
        self.assertEqual(fake.cpu,'running')
        writes = len(fake.writes)
        with self.assertRaisesRegex(RuntimeError,'尚未完成'):
            LunariaBridge.configure(fake,128)
        self.assertEqual(len(fake.writes),writes)
        fake.memory[address+8] = fake.memory[address+12] = 0xffffffff
        fake.set_status(acknowledged_sequence=1)
        self.assertEqual(LunariaBridge.configure(fake,65),0)
        self.assertEqual(fake.writes[-1],(address+8,0))

    def test_settings_invalid_locked_halted_and_old_elf_never_write(self):
        for limit in (-1,0,63,4097,65536,64.5,True):
            fake,_ = self.settings_fake()
            with self.assertRaises(ValueError): LunariaBridge.configure(fake,limit)
            self.assertFalse(fake.writes)
        for status in ({'measurement_state':1},{'phase':1},{'phase':255}):
            fake,_ = self.settings_fake(); fake.set_status(**status)
            with self.assertRaises(RuntimeError): LunariaBridge.configure(fake,128)
            self.assertFalse(fake.writes)
            self.assertEqual(fake.cpu,'running')
        fake,_ = self.settings_fake(); fake.cpu = 'halted'
        with self.assertRaises(RuntimeError): LunariaBridge.configure(fake,128)
        self.assertEqual(fake.cpu,'halted'); self.assertFalse(fake.writes)
        fake,_ = self.settings_fake(); fake.image.symbols.pop('g_lunaria_settings')
        with self.assertRaisesRegex(RuntimeError,'新版'): LunariaBridge.configure(fake,128)
        self.assertFalse(fake.writes)

    def test_tk_construction_without_board(self):
        import tkinter as tk
        from lunaria_debug_window import LunariaWindow
        root = tk.Tk(); root.withdraw()
        try:
            window = LunariaWindow(root)
            root.update_idletasks()
            self.assertIsNone(window.bridge)
            self.assertEqual(window.alpha.get(),'255')
            self.assertEqual(window.cap.get(),'1')
            self.assertFalse(window.invincible.get())
            self.assertEqual(window.bullet_limit.get(),'256')
            self.assertFalse(window.spin_patterns.get())
            window.bullet_limit.set('4097')
            window.apply()
            self.assertIsNone(window.bridge)
            self.assertIn('64–4096',window.rows[-1]['message'])
            self.assertIn('LUNARIA',root.title())
        finally: root.destroy()


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Checks))
    if not result.wasSuccessful(): raise SystemExit(1)
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    report = {'status':'passed','tests':result.testsRun,'board_tested':False,
              'elf_sha256':sha(DEFAULT_ELF),
              'sources':{name:sha(ROOT/name) for name in ('tools/lunaria_debug_bridge.py',
                 'tools/lunaria_debug_window.py','tools/game_debug_bridge.py','tools/game_debug_window.py',
                 'scripts/run_lunaria_loader_checks.py')}}
    (Path(os.environ.get('LUNARIA_OUTPUT_DIR', str(ROOT/'output/lunaria')))/'verification/loader-checks.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print('PASS offline LUNARIA ELF/assets/upload/UI checks; no board connected')
