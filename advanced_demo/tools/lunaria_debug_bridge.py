"""LUNARIA ELF + artwork loader using the firmware's guarded 4 KiB mailbox."""
import hashlib
import json
from pathlib import Path
import os
import struct
import tempfile
import time

from game_debug_bridge import (APB, CodeMismatchError, DebugBridge, DEFAULT_IDE, ROOT, STATUS_FIELDS,
                               CONTROL_MAGIC, tcl_word)

DEFAULT_ELF = ROOT / 'software/lunaria/build/lunaria.elf'
DEFAULT_ASSETS = Path(os.environ.get('LUNARIA_OUTPUT_DIR', str(ROOT/'output/lunaria')))/'assets.json'
MAGIC, WAIT, PROCESS, READY, FAULT = 0x4C4E5531, 1, 2, 3, 255
WORDS, CHUNK_WORDS = 307200, 1024
SETTINGS_MAGIC = 0x4c4e5331
SETTINGS_FIELDS = ('magic version sequence ack result requested_limit requested_spin '
                   'limit spin min_limit capacity').split()
DDR_FIELDS = ('cycles commands busy_cycles source_beats destination_beats write_beats '
              'cache_hits cache_misses read_address_wait read_data_wait write_address_wait '
              'write_data_wait write_response_wait mixed_beats bank_wait overlap_cycles '
              'swaps reader_frame_beats writer_throttle underflows missed').split()


READ_DDR_FIELDS = ('source_address_wait target_address_wait source_first_wait target_first_wait '
                   'source_interbeat_wait target_interbeat_wait source_bursts target_bursts').split()


def ddr_interval(before, after):
    if len(before) not in (21,29) or len(after) != len(before):
        raise ValueError('DDR 快照长度错误')
    delta = {key: (b-a)&0xffffffff for key,a,b in zip(DDR_FIELDS+READ_DDR_FIELDS,before,after)}
    seconds = delta['cycles']/100000000
    # 32-bit clock wraps after 42.95 s; the UI uses a 5 s interval.
    if not 0 < seconds < 40:
        raise ValueError('DDR 采样区间无效，请重新进行 5 秒测量')
    attempts = delta['cache_hits']+delta['cache_misses']
    rates = {key: delta[key]*16/seconds/1e6 for key in
             ('source_beats','destination_beats','write_beats')}
    waits = {key: 100*delta[key]/delta['cycles'] for key in
             ('read_address_wait','read_data_wait','write_address_wait',
              'write_data_wait','write_response_wait','bank_wait','overlap_cycles')}
    return dict(seconds=seconds, counters=delta, alpha_MB_per_second=rates,
                cache_hit_percent=100*delta['cache_hits']/attempts if attempts else None,
                wall_time_percent=waits,
                note='Alpha/激光引擎计数；等待项可重叠。不含背景复制流量；reader_frame_beats 是帧内状态，不用于带宽。起止 JTAG 暂停会扰动 FPS，60 秒验收另测。')
FIELDS = ('magic version state sequence ack window offset count expected_hash '
          'actual_hash error received_background received_atlas background_hash atlas_hash').split()
ERRORS = {0xE000:'固件启动时拒绝硬件 ID/版本；请核对所选 ELF 和配套 bit（支持 v13/v14/v15/v16，推荐 hardware/v16）',
          0xE001:'硬件初始化或绘制结束等待超时',
          0xE003:'硬件能力位、显示参数或 DDR 服务配置不匹配',
          0xEE00:'硬件缺少 LUNARIA 所需能力',
          0xEA01:'素材窗口已开始或部分封存，需要重新配置现有 bit',
          0xEA03:'素材分块序号、窗口或边界不匹配',0xEA04:'上传块校验失败',
          0xEA05:'DDR 回读校验失败',0xEA06:'完整素材哈希不匹配',
          0xEA08:'DDR 中封存的是另一套素材，需要重新配置现有 bit 后重新加载'}


def fnv_words(data):
    if len(data)%4: raise ValueError('ARGB 数据长度必须为四字节倍数')
    h = 2166136261
    for (word,) in struct.iter_unpack('<I',data): h = ((h^word)*16777619)&0xffffffff
    return h


def read_assets(path):
    path = Path(path).resolve()
    manifest = json.loads(path.read_text(encoding='utf8'))
    if manifest.get('version') != 1 or manifest.get('format') != 'little-endian ARGB8888':
        raise ValueError('LUNARIA 素材版本/格式不匹配')
    result = []
    for name in ('background','atlas'):
        item = manifest['assets'][name]
        asset = (path.parent/item['file']).resolve()
        if asset.parent != path.parent: raise ValueError('素材必须位于清单同目录')
        if item['bytes'] != WORDS*4 or item['width'] != 640 or item['height'] != 480:
            raise ValueError('素材尺寸不匹配')
        data = asset.read_bytes()
        if (len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']
                or fnv_words(data) != item['fnv_words']):
            raise ValueError(name+' 素材已损坏或清单不匹配')
        result.append((data,item['fnv_words']))
    return result


class LunariaBridge(DebugBridge):
    def capture_ddr(self):
        with self.halted() as running:
            if not running:
                raise RuntimeError('CPU 原本已暂停，请先继续运行')
            if not self.matched:
                self.verify_code()
            if self.read_words(APB+4,1)[0] not in (0xE0000,0xF0000,0x100000) or not self.read_words(APB+0x40,1)[0]&0x20000:
                raise RuntimeError('DDR 计数需要 hardware/v16 位流和新版 ELF')
            words=self.read_words(APB+0xe8,1)[0]
            if words not in (21,29):
                raise RuntimeError('Unexpected DDR snapshot length')
            self.rpc(f'mww {APB+0xe8:#x} 0x1')
            return self.read_words(APB+0x100,words)

    def measure_ddr(self):
        before = self.capture_ddr()
        time.sleep(5)  # Worker thread only; no JTAG access during the interval.
        return ddr_interval(before,self.capture_ddr())

    def __init__(self, elf=DEFAULT_ELF, ide=DEFAULT_IDE, assets=DEFAULT_ASSETS, progress=None):
        super().__init__(elf,ide)
        self.assets = Path(assets)
        self.progress = progress or (lambda message: None)
        if self.image.symbol_u32('g_lunaria_available') != 1:
            raise ValueError('请选择 LUNARIA ELF；旧游戏请使用原调试窗口')
        self.upload_address = self.image.symbol('g_lunaria_upload',4*len(FIELDS))
        self.chunk_address = self.image.symbol('g_lunaria_chunk',4096)
        if self.chunk_address & 15: raise ValueError('上传缓冲区未对齐')
        self.asset_hashes = [self.image.symbol_u32('g_lunaria_asset_hashes',n) for n in range(2)]

    def _mailbox(self):
        with self.halted() as running:
            if not running: raise RuntimeError('上传需要 CPU 运行；请继续固件后再试')
            values = self.read_words(self.upload_address,len(FIELDS))
        return dict(zip(FIELDS,values))

    def _wait(self, predicate, seconds=20):
        deadline = time.monotonic()+seconds
        while True:
            status = self._mailbox()
            # Earlier firmware can fail accel_init before upload() sets magic.
            # A fresh, verified ELF was loaded; report that boot fault directly.
            early_fault = (status['magic'] == 0 and status['version'] == 0 and
                           status['state'] == FAULT and status['error'])
            if early_fault:
                error = status['error']
                raise RuntimeError(f'LUNARIA 启动故障 0x{error:04X}: '+ERRORS.get(error,'请导出日志检查'))
            if status['magic'] == MAGIC and status['version'] == 1:
                if status['state'] == FAULT or status['error']:
                    error = status['error']
                    raise RuntimeError(f'LUNARIA 故障 0x{error:04X}: '+ERRORS.get(error,'请导出日志检查')+'; upload='+json.dumps(status,ensure_ascii=False))
                if predicate(status): return status
            if time.monotonic() >= deadline:
                raise TimeoutError('LUNARIA 素材上传等待确认超时；不自动重试。'+str(status))
            time.sleep(0.05)

    def _put(self, window, offset, data, sequence, path):
        count = len(data)//4
        if window not in (0,1) or not 0 < count <= CHUNK_WORDS or len(data)%4:
            raise ValueError('非法素材分块')
        if offset < 0 or offset+count > WORDS: raise ValueError('素材分块越界')
        expected = fnv_words(data)
        path.write_bytes(data)
        with self.halted() as running:
            if not running: raise RuntimeError('CPU 已暂停，无法接收素材')
            status = dict(zip(FIELDS,self.read_words(self.upload_address,len(FIELDS))))
            if (status['magic'] != MAGIC or status['version'] != 1 or status['state'] != WAIT
                    or status['sequence'] != sequence-1 or status['ack'] != sequence-1
                    or status['error'] or status['received_background' if window == 0 else 'received_atlas'] != offset
                    or (window == 1 and status['received_background'] != WORDS)):
                raise RuntimeError('素材邮箱状态发生变化，停止写入：'+str(status))
            # Write only OCRAM; the firmware alone acquires DDR ownership.
            self.rpc('load_image '+tcl_word(path.as_posix())+f' {self.chunk_address:#x} bin')
            for index,value in ((5,window),(6,offset),(7,count),(8,expected)):
                self.rpc(f'mww {self.upload_address+index*4:#x} {value:#x}')
            # sequence commits a complete descriptor, always last.
            self.rpc(f'mww {self.upload_address+12:#x} {sequence:#x}')
        status = self._wait(lambda s: s['ack'] == sequence)
        received = status['received_background' if window == 0 else 'received_atlas']
        target_state = READY if window == 1 and offset+count == WORDS else WAIT
        if (status['actual_hash'] != expected or received != offset+count
                or status['state'] != target_state or status['sequence'] != sequence):
            raise RuntimeError('素材分块确认/回读哈希不匹配：'+str(status))
        return status

    def upload_assets(self, assets):
        status = self._wait(lambda s: s['state'] in (WAIT,READY))
        if status['state'] == READY:
            if ([status['background_hash'],status['atlas_hash']] != self.asset_hashes
                    or status['received_background'] != WORDS or status['received_atlas'] != WORDS):
                raise RuntimeError('现有封存素材校验不匹配')
            self.progress('已回读校验并复用相同素材，无需重复上传')
            return
        if status['sequence'] or status['ack'] or status['received_background'] or status['received_atlas']:
            raise RuntimeError('检测到中断上传；重新配置现有 bit 后再加载，不自动续传')
        sequence = 0
        with tempfile.TemporaryDirectory(prefix='lunaria-chunk-') as folder:
            path = Path(folder)/'chunk.bin'
            for window,(data,expected_hash) in enumerate(assets):
                for offset in range(0,WORDS,CHUNK_WORDS):
                    sequence += 1
                    count = min(CHUNK_WORDS,WORDS-offset)
                    status = self._put(window,offset,data[offset*4:(offset+count)*4],sequence,path)
                    if sequence%30 == 0:
                        self.progress(f'素材上传 {sequence}/600 块（{sequence//6}%），每块已 DDR 回读校验')
                field = 'background_hash' if window == 0 else 'atlas_hash'
                if status[field] != expected_hash: raise RuntimeError('素材整体校验不匹配')
        self.progress('背景和图集已完整校验并封存，进入标题画面')

    def load(self):
        assets = read_assets(self.assets) # Validate before any hardware mutation.
        if [h for _,h in assets] != self.asset_hashes:
            raise ValueError('ELF 与素材包不匹配，请使用同一次构建的 ELF 和 assets.json')
        with self.halted():
            version = self.read_words(APB+4,1)[0]
            if version not in (0xD0000,0xE0000,0xF0000,0x100000):
                raise RuntimeError('本交付包需要 v13/v14/v15/v16 bit，DDR 优化请配置 hardware/v16 的位流')
        self.progress('ELF 和素材本地校验完成，等待安全加载边界')
        super().load()
        self.upload_assets(assets)

    def configure(self, limit, spin=False, options=None):
        """Commit one frame-boundary settings request; never reset/load the board."""
        if type(limit) is not int or not 64 <= limit <= 4096 or spin not in (0, 1):
            raise ValueError('敌弹上限须为 64–4096 的整数')
        if options is not None:
            delay, interval, cap, invincible, alpha = options
            if not (delay == 0 and interval == 900 and cap == 1 and
                    invincible in (0, 1) and 0 <= alpha <= 255):
                raise ValueError('Alpha 须为 0–255 的整数')
        if 'g_lunaria_settings' not in self.image.symbols:
            raise RuntimeError('当前 ELF 不支持子弹数量设置，请加载新版 LUNARIA ELF')
        with self.halted() as running:
            if not running:
                raise RuntimeError('CPU 原本已暂停，请先在原调试器继续运行')
            if not self.matched:
                self.verify_code()
            address = self.image.symbol('g_lunaria_settings',4*len(SETTINGS_FIELDS))
            values = dict(zip(SETTINGS_FIELDS,self.read_words(address,len(SETTINGS_FIELDS))))
            if (values['magic'] != SETTINGS_MAGIC or values['version'] != 1 or
                    values['capacity'] != self.image.symbol_u32('g_lunaria_settings',10) or
                    not values['min_limit'] <= limit <= values['capacity']):
                raise RuntimeError('板上子弹设置接口或容量与所选 ELF 不匹配')
            if values['sequence'] != values['ack']:
                raise RuntimeError('上一条子弹设置尚未完成，请稍后读取状态')
            status_address = self.image.symbol('g_debug_status',4*len(STATUS_FIELDS))
            status = dict(zip(STATUS_FIELDS,self.read_words(status_address,len(STATUS_FIELDS))))
            if status['phase'] != 4 or status['measurement_state'] == 1:
                raise RuntimeError('初始化、故障或 60 秒测量期间不能设置子弹数量')
            control = self.image.symbol('g_debug_control',32)
            words = self.read_words(control,8)
            if words[0] != CONTROL_MAGIC or words[1] != status['acknowledged_sequence']:
                raise RuntimeError('上一条游戏命令尚未完成，请稍后读取状态')
            sequence = (values['sequence'] + 1) & 0xffffffff
            self.rpc(f'mww {address+20:#x} {limit:#x}')
            self.rpc(f'mww {address+24:#x} {int(spin):#x}')
            if options is not None:
                for i,value in enumerate(options,3):
                    self.rpc(f'mww {control+i*4:#x} {int(value):#x}')
                self.rpc(f'mww {control+8:#x} 0x4')
                self.rpc(f'mww {control+4:#x} {(words[1]+1)&0xffffffff:#x}')
            self.rpc(f'mww {address+8:#x} {sequence:#x}')
        return sequence

    def snapshot(self, verify=False):
        try:
            return self._verified_snapshot(verify)
        except CodeMismatchError as exc:
            # Diagnostic evidence only. These symbol-derived RAM values are
            # unverified and cannot enable upload, settings, or game commands.
            evidence={'code_verified':False,'symbol_layout_verified':False}
            try:
                with self.halted():
                    evidence['hardware']={hex(offset):self.read_words(APB+offset,1)[0]
                        for offset in (0,4,0x24,0x40,0x78,0xD0,0xD4,0xDC,0xE4)}
                    address=self.image.symbol('g_lunaria_upload',4*len(FIELDS))
                    evidence['upload_address']=hex(address)
                    evidence['unverified_upload']=dict(zip(FIELDS,self.read_words(address,len(FIELDS))))
            except Exception as diagnostic_error:
                evidence['diagnostic_error']=str(diagnostic_error)
            if evidence.get('hardware',{}).get('0x0')==0:
                evidence['interpretation']='硬件 ID 也读成零，当前目标读取不可用；不能据此认定 ELF 版本不匹配。请重新配置配套 bit 后恢复，保留原始故障记录。'
            raise CodeMismatchError(str(exc)+'; raw_diagnostics='+
                                    json.dumps(evidence,ensure_ascii=False)) from exc

    def _verified_snapshot(self, verify=False):
        status = super().snapshot(verify)
        status['lunaria'] = True
        # Read-only: preserve the failed upload's block/sequence for export.
        with self.halted():
            upload=self.read_words(self.upload_address,len(FIELDS))
        if upload[:2]==[MAGIC,1]:
            status['lunaria_upload']=dict(zip(FIELDS,upload))
        if 'g_lunaria_timing' in self.image.symbols:
            address=self.image.symbol('g_lunaria_timing',28)
            with self.halted():
                values=self.read_words(address,7)
            if values[:2]==[0x4c4e5431,1]:
                status['lunaria_timing']=dict(zip(
                    ('publication','update_us','submit_us','drain_us','swap_us'),values[2:]))
                status['partial_lunaria_timing']=bool(values[2]&1)
        if 'g_lunaria_metrics' in self.image.symbols:
            address = self.image.symbol('g_lunaria_metrics',36)
            with self.halted():
                values = self.read_words(address,9)
            if values[0:2] == [0x4c4e4d31,1]:
                status['lunaria_metrics'] = dict(zip(
                    ('publication','fps_x100','bullets','peak_bullets','elements','peak_elements','deferred_emissions'),
                    values[2:]))
                status['partial_lunaria_metrics'] = bool(values[2]&1)
        if 'g_lunaria_settings' in self.image.symbols:
            address = self.image.symbol('g_lunaria_settings',4*len(SETTINGS_FIELDS))
            with self.halted():
                values = self.read_words(address,len(SETTINGS_FIELDS))
            if values[:2] == [SETTINGS_MAGIC,1]:
                status['lunaria_settings'] = dict(zip(SETTINGS_FIELDS,values))
        return status
