"""A rede do Chord-CNN-LSTM (ChordNet e CNNFeatureExtractor de chordnet_ismir_naive.py do original), só a inferência:
sem a perda, o treino e a GPU. As camadas e os nomes são os do original, para os pesos carregarem como estão."""

import torch
import torch.nn as nn
import torch.nn.functional as F

from .complex_chord import ChordTypeLimit

SHIFT_HIGH = 6
SHIFT_STEP = 3
SPEC_DIM = 252

chord_limit = ChordTypeLimit(
    triad_limit=6,
    seventh_limit=3,
    ninth_limit=3,
    eleventh_limit=2,
    thirteenth_limit=2,
)


class CNNFeatureExtractor(nn.Module):

    def norm_layer(self, channels):
        return nn.InstanceNorm2d(channels)

    def __init__(self):
        super().__init__()
        self.cdim1 = 16
        self.cdim2 = 32
        self.cdim3 = 64
        self.cdim4 = 80
        self.conv1a = nn.Conv2d(1, self.cdim1, (3, 3), padding=(1, 1))
        self.norm1a = self.norm_layer(self.cdim1)
        self.conv1b = nn.Conv2d(self.cdim1, self.cdim1, (3, 3), padding=(1, 1))
        self.norm1b = self.norm_layer(self.cdim1)
        self.conv1c = nn.Conv2d(self.cdim1, self.cdim1, (3, 3), padding=(1, 1))
        self.norm1c = self.norm_layer(self.cdim1)
        self.pool1 = nn.MaxPool2d((1, 3))
        self.conv2a = nn.Conv2d(self.cdim1, self.cdim2, (3, 3), padding=(1, 1))
        self.norm2a = self.norm_layer(self.cdim2)
        self.conv2b = nn.Conv2d(self.cdim2, self.cdim2, (3, 3), padding=(1, 1))
        self.norm2b = self.norm_layer(self.cdim2)
        self.conv2c = nn.Conv2d(self.cdim2, self.cdim2, (3, 3), padding=(1, 1))
        self.norm2c = self.norm_layer(self.cdim2)
        self.pool2 = nn.MaxPool2d((1, 3))
        self.conv3a = nn.Conv2d(self.cdim2, self.cdim3, (3, 3), padding=(1, 1))
        self.norm3a = self.norm_layer(self.cdim3)
        self.conv3b = nn.Conv2d(self.cdim3, self.cdim3, (3, 3), padding=(1, 1))
        self.norm3b = self.norm_layer(self.cdim3)
        self.pool3 = nn.MaxPool2d((1, 4))
        self.conv4a = nn.Conv2d(self.cdim3, self.cdim4, (3, 3), padding=(1, 0))
        self.norm4a = self.norm_layer(self.cdim4)
        self.conv4b = nn.Conv2d(self.cdim4, self.cdim4, (3, 3), padding=(1, 0))
        self.norm4b = self.norm_layer(self.cdim4)
        self.output_size = 3 * self.cdim4

    def forward(self, x):
        batch_size = x.shape[0]
        seq_length = x.shape[1]
        x = x.view((batch_size, 1, seq_length, SPEC_DIM))
        x = F.selu(self.norm1a(self.conv1a(x)))
        x = F.selu(self.norm1b(self.conv1b(x)))
        x = F.selu(self.norm1c(self.conv1c(x)))
        x = self.pool1(x)
        x = F.selu(self.norm2a(self.conv2a(x)))
        x = F.selu(self.norm2b(self.conv2b(x)))
        x = F.selu(self.norm2c(self.conv2c(x)))
        x = self.pool2(x)
        x = F.selu(self.norm3a(self.conv3a(x)))
        x = F.selu(self.norm3b(self.conv3b(x)))
        x = self.pool3(x)
        x = F.selu(self.norm4a(self.conv4a(x)))
        x = F.selu(self.norm4b(self.conv4b(x)))
        return x.transpose(1, 2).contiguous().view((batch_size, seq_length, self.output_size))


class ChordNet(nn.Module):

    def __init__(self):
        super().__init__()
        self.audio_feature_block = CNNFeatureExtractor()
        # Sem uso na inferência, mas está nos pesos do original.
        self.condition_linear = nn.Linear(self.audio_feature_block.output_size + 12 + chord_limit.triad_limit + 12, 128)
        self.hidden_dim1 = 192
        self.lstm1 = nn.LSTM(input_size=self.audio_feature_block.output_size, hidden_size=self.hidden_dim1 // 2,
                             num_layers=1, bidirectional=True, batch_first=True)
        self.output_dim1 = chord_limit.triad_limit * 12 + 2 + 12
        self.output_dim2 = (chord_limit.seventh_limit + chord_limit.ninth_limit + chord_limit.eleventh_limit
                            + chord_limit.thirteenth_limit + 4)
        self.final_fc1 = nn.Linear(self.hidden_dim1, self.output_dim1 + self.output_dim2)

    def forward(self, x):
        batch_size = x.shape[0]
        seq_length = x.shape[1]
        x = self.audio_feature_block(x)
        hidden = (torch.zeros(2, batch_size, self.hidden_dim1 // 2), torch.zeros(2, batch_size, self.hidden_dim1 // 2))
        x1 = self.lstm1(x, hidden)[0]
        x1 = self.final_fc1(x1).reshape((batch_size * seq_length, self.output_dim1 + self.output_dim2))
        bass_del = chord_limit.bass_slice_begin + 12 + 1
        seventh_del = bass_del + chord_limit.seventh_limit + 1
        ninth_del = seventh_del + chord_limit.ninth_limit + 1
        eleventh_del = ninth_del + chord_limit.eleventh_limit + 1
        thirteenth_del = eleventh_del + chord_limit.thirteenth_limit + 1
        return (x1[:, :chord_limit.bass_slice_begin], x1[:, chord_limit.bass_slice_begin:bass_del],
                x1[:, bass_del:seventh_del], x1[:, seventh_del:ninth_del], x1[:, ninth_del:eleventh_del],
                x1[:, eleventh_del:thirteenth_del])

    def inference(self, x):
        """As probabilidades de cada quadro (a tríade, o baixo, a sétima, a nona, a décima primeira e a décima
        terceira) a partir do CQT (quadros × 288)."""
        seq_length = x.shape[0]
        start = SHIFT_HIGH * SHIFT_STEP
        output = self(x[:, start:start + SPEC_DIM].reshape((1, seq_length, SPEC_DIM)))
        return tuple(F.softmax(part, dim=1).cpu().numpy() for part in output)
