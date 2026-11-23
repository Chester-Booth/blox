"""Serialisation-boundary regression checks, without PTYs or live providers."""
import copy
import json
import unittest
from blox_widgets.broker import OutputQueue, MAX_CONSUMERS
from blox_widgets.terminal import AnsiScreen

class WireTests(unittest.TestCase):
    def setUp(self):
        self.q = OutputQueue()
        self.screen = AnsiScreen(3, 8)
        self.frames = {}
    def emit(self, revision, consumer='a', generation=1, attempt=1, sequence=None):
        rows = [dict(runs=self.screen.runs(r)) for r in range(self.screen.rows)]
        value = dict(rows=rows, changedRuns=[], generation=generation, attempt=attempt,
            sequence=revision if sequence is None else sequence, columns=self.screen.columns, rowCount=self.screen.rows)
        message = dict(_terminal=True, consumerId=consumer, snapshot=dict(generation=generation,
            revision=revision, value=value, state='ready', error='', observedMonotonicMs=revision))
        saved = copy.deepcopy(message)
        self.q.emit(message)
        return message, saved
    def take(self, first=None):
        raw = bytearray(first or b'')
        while self.q.active or not raw:
            part = self.q.chunk(7)
            raw.extend(part); self.q.advance(len(part))
        message = json.loads(raw)
        if 'snapshot' not in message:return message
        id = message['consumerId']; v=message['snapshot']['value']
        if v['rowFormat']=='full-v1':rows=copy.deepcopy(v['rows'])
        else:
            old=self.frames[id]
            self.assertEqual((v['baseRevision'],v['baseSequence']),old[:2])
            rows=copy.deepcopy(old[2])
            for index,row in v['rowPatches']:rows[index]=row
        self.frames[id]=(message['snapshot']['revision'],v['sequence'],rows)
        return message
    def test_partial_write_coalescing_erases_revision_holes_fanout(self):
        self.screen.feed('界A\r\x1b[P'.encode())
        original,saved=self.emit(1)
        prefix=self.q.chunk(11); self.q.advance(len(prefix))
        self.screen.feed(b'\x1b[2;1HRED')
        self.emit(2); self.emit(2,'b')
        self.screen.feed(b'\x1b[2;1H\x1b[2K')
        latest,_=self.emit(19)
        self.take(prefix)
        patch=self.take()['snapshot']['value']
        self.assertEqual(patch['rowFormat'],'patch-v1')
        self.assertEqual(self.frames['a'][2],latest['snapshot']['value']['rows'])
        self.assertEqual(self.take()['snapshot']['value']['rowFormat'],'full-v1')
        self.assertEqual(original,saved)
        self.assertEqual(self.q.wire_bases['a'][1],19)
    def test_full_frame_differential_ansi_corpus_and_metadata_only(self):
        corpus=[b'hello', '界e\u0301'.encode(), b'\r\x1b[P', b'\x1b[2;1H\x1b[41mRED',
            b'\x1b[0m\x1b[2J', b'\x1b[?1049hALT', b'\x1b[?1049l', b'\r\nSCROLL\r\nMORE\r\nEND',
            b'\x1b[1;1H\x1b[@', b'\x1b[2K', b'']
        for index,data in enumerate(corpus):
            self.screen.feed(data)
            if index==7:self.screen.resize(10,4)
            for consumer in ('a','b'):
                # These intermediate observations are deliberately not serialised.
                self.emit(index*10+1,consumer)
                expected,_=self.emit(index*10+9,consumer)
                self.take()
                self.assertEqual(self.frames[consumer][2],expected['snapshot']['value']['rows'])
        # Empty observations invalidate the transport base too.
        self.q.emit(dict(_terminal=True,consumerId='a',snapshot=dict(value={},state='unavailable')))
        raw=self.q.chunk();self.q.advance(len(raw))
        self.assertNotIn('a',self.q.wire_bases)
        self.emit(999)
        self.assertEqual(self.take()['snapshot']['value']['rowFormat'],'full-v1')

    def test_unsubscribe_partial_active_pending_replacement_reset(self):
        self.emit(1); prefix=self.q.chunk(9); self.q.advance(len(prefix))
        self.emit(2); self.q.cancel_consumer('a')
        self.emit(1,generation=2)
        self.take(prefix)
        self.assertEqual(self.take()['snapshot']['value']['rowFormat'],'full-v1')
        self.emit(2,generation=2); self.q.chunk(); self.q.cancel_consumer('a')
        self.assertFalse(self.q); self.assertNotIn('a',self.q.wire_bases)
        for revision,kwargs in [(3,{}),(4,dict(attempt=2)),(5,dict(generation=3))]:
            self.emit(revision,**kwargs)
            self.assertEqual(self.take()['snapshot']['value']['rowFormat'],'full-v1')
        self.screen.resize(9,2); self.emit(6,generation=3)
        self.assertEqual(self.take()['snapshot']['value']['rowFormat'],'full-v1')
        self.q=OutputQueue(); self.emit(7,generation=3)
        self.assertEqual(self.take()['snapshot']['value']['rowFormat'],'full-v1')
    def test_fairness_controls_and_bounded_retention(self):
        for i in range(MAX_CONSUMERS):self.emit(1,str(i))
        self.emit(2,'0')
        self.q.emit(dict(requestId=1,ok=True))
        self.assertEqual(self.take(),dict(requestId=1,ok=True))
        ids=[self.take()['consumerId'] for _ in range(MAX_CONSUMERS)]
        self.assertEqual(ids,[str(i) for i in range(MAX_CONSUMERS)])
        for i in range(MAX_CONSUMERS,MAX_CONSUMERS*2):
            self.emit(1,str(i)); self.take()
        self.assertLessEqual(len(self.q.wire_bases),MAX_CONSUMERS)
        for id in list(self.q.wire_bases):self.q.cancel_consumer(id)
        self.assertFalse(self.q.wire_bases)

if __name__=='__main__':unittest.main()
