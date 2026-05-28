import torch
import torch.nn as nn
import torch.nn.functional as F

class CNN(nn.Module):
    def __init__(self):
        super(CNN, self).__init__()
        self.conv1 = nn.Conv2d(1, 3, kernel_size=5)
        self.conv2 = nn.Conv2d(3, 3, kernel_size=5)
        self.mp    = nn.MaxPool2d(2)
        self.fc_1  = nn.Linear(48, 10)

    def forward(self, x):
        x = F.relu(self.mp(self.conv1(x)))   # conv1 → pool → relu
        x = F.relu(self.mp(self.conv2(x)))   # conv2 → pool → relu
        x = x.view(x.size(0), -1)            # flatten
        x = self.fc_1(x)
        return x                              # NO log_softmax — remove it!