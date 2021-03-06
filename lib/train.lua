require 'cunn'
require 'optim'

local matio = require 'matio'
local Logger = require 'lib/util/Logger'
local geometry = require 'lib/util/geometry'
local img = require 'lib/util/img'
local eval = require 'lib/util/eval'
local util = require 'common/util'

local M = {}
local Trainer = torch.class('skeleton2d3d.Trainer', M)

function Trainer:__init(model, criterion, opt, optimState)
  self.model = model
  self.criterion = criterion
  self.optimState = optimState or {
    learningRate = opt.LR,
    weightDecay = opt.weightDecay,
  }
  self.opt = opt
  self.params, self.gradParams = model:getParameters()
  self.logger = {
    train = Logger(paths.concat(opt.save, 'train.log'), opt.resume),
    val = Logger(paths.concat(opt.save, 'val.log'), opt.resume),
  }
  self:initLogger(self.logger['train'])
  self:initLogger(self.logger['val'])
  -- Set log format
  if self.opt.dataset == 'h36m' then
    if #self.model.outnode.children == 1 then
      self.format_l = '%7.5f'
      self.format_e = '%7.5f'
    else
      self.format_l = '%7.0f'
      self.format_e = '%7.2f'
    end
  end
  if self.opt.dataset == 'penn-crop' then
    self.format_l = '%7.4f'
    self.format_e = '%7.4f'
  end
  self.nOutput = #self.model.outnode.children
  self.jointType = opt.dataset
  if opt.penn then
    self.jointType = 'penn-crop'
  end
end

function Trainer:initLogger(logger)
  local names = {}
  names[1] = 'epoch'
  names[2] = 'iter'
  names[3] = 'time'
  names[4] = 'datTime'
  names[5] = 'loss'
  names[6] = 'err'
  names[7] = 'acc'
  logger:setNames(names)
end

function Trainer:train(epoch, loaders)
  local timer = torch.Timer()
  local dataTimer = torch.Timer()

  local function feval()
    return self.criterion.output, self.gradParams
  end

  local dataloader = loaders['train']
  local size = dataloader:size()

  print(('=> Training epoch # %d'):format(epoch))
  xlua.progress(0, size)

  -- Set the batch norm to training mode
  self.model:training()
  for i, sample in dataloader:run({train=true}) do
    local dataTime = dataTimer:time().real
  
    -- Get input/output and convert to CUDA
    local input = sample.input:cuda()
    local repos = sample.repos:cuda()
    local trans = sample.trans:cuda()
    local focal = sample.focal:cuda()
    local hmap = sample.hmap:cuda()
    local proj = sample.proj:cuda()
    
    -- Get target
    local target
    if not self.opt.hg then
      target = {repos, trans, focal}
    end

    -- Forward pass
    local output = self.model:forward(input)
    if self.opt.hg then
      if self.nOutput == 1 then
        target = hmap
      else
        local proj_ = proj:clone()
        proj_[proj_:eq(0)] = output[5][proj_:eq(0)]
        target = {hmap, repos, trans, focal, proj_}
      end
    end
    local loss = self.criterion:forward(self.model.output, target)

    -- Backprop
    self.model:zeroGradParameters()
    self.criterion:backward(self.model.output, target)
    self.model:backward(input, self.criterion.gradInput)

    -- Optimization
    optim.rmsprop(feval, self.params, self.optimState)

    -- Compute mean per joint position error (MPJPE)
    if self.nOutput == 1 then output = {output} end
    local pred, err, acc, num, ne, na
    local center, scale = sample.center, sample.scale
    local gtpts = sample.gtpts
    local ref = self:getRef(scale)
    if self.nOutput == 1 then
      pred = eval.getPreds(output[1]:float())
      pred = self:getOrigCoord(pred,center,scale)
      err, ne = self:_computeError(pred,gtpts,ref)
      acc, na = self:_computeAccuracy(pred,gtpts,ref)
      assert(ne == na)
      err = err / ne
      acc = acc / ne
    else
      repos = repos:float()
      if self.opt.hg then
        pred = output[2]:float()
      else
        pred = output[1]:float()
      end
      err = torch.csub(repos,pred):pow(2):sum(3):sqrt():sum()
      acc = 0/0
      num = pred:numel()/3
      err = err / num
      -- store 2d error to acc for hg
      if self.opt.hg then
        pred = output[5]:float()
        pred = self:getOrigCoord(pred,center,scale)
        acc, na = self:_computeAccuracy(pred,gtpts,ref)
        assert(na == num)
        acc = acc / na
      end
    end

    -- Print and log
    local time = timer:time().real
    local entry = {}
    entry[1] = string.format("%d" % epoch)
    entry[2] = string.format("%d" % i)
    entry[3] = string.format("%.3f" % time)
    entry[4] = string.format("%.3f" % dataTime)
    entry[5] = string.format(self.format_l % loss)
    entry[6] = string.format(self.format_e % err)
    entry[7] = string.format("%7.5f" % acc)
    self.logger['train']:add(entry)
  
    xlua.progress(i, size)

    timer:reset()
    dataTimer:reset()
  end
end

function Trainer:test(epoch, iter, loaders, split)
  local testTimer = torch.Timer()

  local dataloader = loaders[split]
  local size = dataloader:sizeDataset()
  local lossSum, errSum, accSum, numSum, N = 0.0, 0.0, 0.0, 0.0, 0.0

  print("=> Test on " .. split)
  xlua.progress(0, size)

  self.model:evaluate()
  for i, sample in dataloader:run({train=false}) do
    -- Get input/output and convert to CUDA
    local input = sample.input:cuda()
    local repos = sample.repos:cuda()
    local trans = sample.trans:cuda()
    local focal = sample.focal:cuda()
    local hmap = sample.hmap:cuda()
    local proj = sample.proj:cuda()

    -- Get target
    local target
    if not self.opt.hg then
      target = {repos, trans, focal}
    end

    -- Forward pass
    local output = self.model:forward(input)
    if self.opt.hg then
      if self.nOutput == 1 then
        local hmap1 = output[{{1}}]
        local hmap2 = img.flip(img.shuffleLR(output[{{2}}],self.jointType))
        output = torch.add(hmap1,hmap2):div(2)
        target = hmap
      else
        local hmap1 = output[1][{{1}}]
        local hmap2 = img.flip(img.shuffleLR(output[1][{{2}}],self.jointType))
        local repos1 = output[2][{{1}}]
        local repos2 = geometry.flip(geometry.shuffleLR(output[2][{{2}}],self.jointType))
        local trans1 = output[3][{{1}}]
        local trans2 = geometry.flip(output[3][{{2}}])
        local proj1 = output[5][{{1}}]
        local proj2 = geometry.shuffleLR(output[5][{{2}}],self.jointType)
        local ind = proj2:eq(0)
        proj2[{{},{},1}] = self.opt.inputRes - proj2[{{},{},1}] + 1
        proj2[ind] = 0
        output[1] = torch.add(hmap1,hmap2):div(2)
        output[2] = torch.add(repos1,repos2):div(2)
        output[3] = torch.add(trans1,trans2):div(2)
        output[4] = output[4]:mean(1)
        output[5] = torch.add(proj1,proj2):div(2)
        local proj_ = proj:clone()
        proj_[proj_:eq(0)] = output[5][proj_:eq(0)]
        target = {hmap, repos, trans, focal, proj_}
      end
    end
    local loss = self.criterion:forward(output, target)

    -- Compute mean per joint position error (MPJPE)
    if self.opt.hg then
      assert(input:size(1) == 2, 'batch size must be 2 with run({train=false})')
    else
      assert(input:size(1) == 1, 'batch size must be 1 with run({train=false})')
    end
    if self.nOutput == 1 then output = {output} end
    local pred, err, acc, num, ne, na
    local center, scale = sample.center, sample.scale
    local gtpts = sample.gtpts
    local ref = self:getRef(scale)
    if self.opt.dataset == 'h36m' then
      if self.nOutput == 1 then
        pred = eval.getPreds(output[1]:float())
        pred = self:getOrigCoord(pred,center,scale)
        err, ne = self:_computeError(pred,gtpts,ref)
        acc, na = self:_computeAccuracy(pred,gtpts,ref)
        assert(ne == na)
        num = ne
      else
        repos = repos:float()
        if self.opt.hg then
          pred = output[2]:float()
        else
          pred = output[1]:float()
        end
        err = torch.csub(repos,pred):pow(2):sum(3):sqrt():sum()
        acc = 0/0
        num = pred:numel()/3
        -- store 2d error to acc for hg
        if self.opt.hg then
          pred = output[5]:float()
          pred = self:getOrigCoord(pred,center,scale)
          acc, na = self:_computeAccuracy(pred,gtpts,ref)
          assert(na == num)
        end
      end
    end
    if self.opt.dataset == 'penn-crop' then
      pred = output[5]:float()
      pred = self:getOrigCoord(pred,center,scale)
      err, ne = self:_computeError(pred,gtpts,ref)
      acc, na = self:_computeAccuracy(pred,gtpts,ref)
      assert(ne == na)
      num = ne
    end

    lossSum = lossSum + loss
    errSum = errSum + err
    accSum = accSum + acc
    numSum = numSum + num
    N = N + 1

    xlua.progress(i, size)
  end
  self.model:training()

  local loss = lossSum / N
  local err = errSum / numSum
  local acc = accSum / numSum

  -- Print and log
  local testTime = testTimer:time().real
  local entry = {}
  entry[1] = string.format("%d" % epoch)
  entry[2] = string.format("%d" % iter)
  entry[3] = string.format("%.3f" % testTime)
  entry[4] = string.format("%.3f" % 0/0)
  entry[5] = string.format(self.format_l % loss)
  entry[6] = string.format(self.format_e % err)
  entry[7] = string.format("%7.5f" % acc)
  self.logger['val']:add(entry)

  return err, acc
end

function Trainer:predict(loaders, split)
  local dataloader = loaders[split]
  local size = dataloader:sizeDataset()
  local inds = torch.IntTensor(size)
  local poses, repos, trans, focal, proj

  print("=> Generating predictions ...")
  xlua.progress(0, size)

  self.model:evaluate()
  for i, sample in dataloader:run({train=false}) do
    -- Get input and convert to CUDA
    local index = sample.index
    local input = sample.input:cuda()

    -- Forward pass
    local output = self.model:forward(input)
    if self.opt.hg then
      if self.nOutput == 1 then
        local hmap1 = output[{{1}}]
        local hmap2 = img.flip(img.shuffleLR(output[{{2}}],self.jointType))
        output = torch.add(hmap1,hmap2):div(2)
      else
        local hmap1 = output[1][{{1}}]
        local hmap2 = img.flip(img.shuffleLR(output[1][{{2}}],self.jointType))
        local repos1 = output[2][{{1}}]
        local repos2 = geometry.flip(geometry.shuffleLR(output[2][{{2}}],self.jointType))
        local trans1 = output[3][{{1}}]
        local trans2 = geometry.flip(output[3][{{2}}])
        local proj1 = output[5][{{1}}]
        local proj2 = geometry.shuffleLR(output[5][{{2}}],self.jointType)
        local ind = proj2:eq(0)
        proj2[{{},{},1}] = self.opt.inputRes - proj2[{{},{},1}] + 1
        proj2[ind] = 0
        output[1] = torch.add(hmap1,hmap2):div(2)
        output[2] = torch.add(repos1,repos2):div(2)
        output[3] = torch.add(trans1,trans2):div(2)
        output[4] = output[4]:mean(1)
        output[5] = torch.add(proj1,proj2):div(2)
      end
    end

    -- Copy output
    if self.opt.hg then
      assert(input:size(1) == 2, 'batch size must be 2 with run({train=false})')
    else
      assert(input:size(1) == 1, 'batch size must be 1 with run({train=false})')
    end
    inds[i] = index[1]
    if self.nOutput == 1 then output = {output} end

    if self.opt.hg then
      if self.nOutput ~= 1 then
        if not poses then
          poses = torch.FloatTensor(size, unpack(sample.repos[1]:size():totable()))
        end
        if not repos then
          repos = torch.FloatTensor(size, unpack(output[2][1]:size():totable()))
        end
        if not trans then
          trans = torch.FloatTensor(size, unpack(output[3][1]:size():totable()))
        end
        if not focal then
          focal = torch.FloatTensor(size, unpack(output[4][1]:size():totable()))
        end
        if not proj then
          proj = torch.FloatTensor(size, unpack(output[5][1]:size():totable()))
        end
        poses[i]:copy(sample.repos[1] + sample.trans[1]:view(1,3):expand(sample.repos[1]:size()))
        repos[i]:copy(output[2]:float()[1])
        trans[i]:copy(output[3]:float()[1])
        focal[i]:copy(output[4]:float()[1])
        proj[i]:copy(output[5]:float()[1])
      end

      -- Save heatmap output
      local hmap_path = paths.concat(self.opt.save,'hmap_' .. split)
      local hmap_file = paths.concat(hmap_path, string.format("%05d.mat" % index[1]))
      util.makedir(hmap_path)
      if not paths.filep(hmap_file) then
        matio.save(hmap_file, {hmap = output[1]:float()[1]})
      end
      -- Save eval output
      local eval_path = paths.concat(self.opt.save,'eval_' .. split)
      local eval_file = paths.concat(eval_path, string.format("%05d.mat" % index[1]))
      util.makedir(eval_path)
      if not paths.filep(eval_file) then
        local center, scale = sample.center, sample.scale
        local pred
        if self.nOutput == 1 then
          pred = eval.getPreds(output[1]:float())
        else
          pred = output[5]:float()
        end
        local eval = self:getOrigCoord(pred,center,scale)[1]
        matio.save(eval_file, {eval = eval})
      end
    else
      if not poses then
        poses = torch.FloatTensor(size, unpack(sample.repos[1]:size():totable()))
      end
      if not repos then
        repos = torch.FloatTensor(size, unpack(output[1][1]:size():totable()))
      end
      if not trans then
        trans = torch.FloatTensor(size, unpack(output[2][1]:size():totable()))
      end
      if not focal then
        focal = torch.FloatTensor(size, unpack(output[3][1]:size():totable()))
      end
      poses[i]:copy(sample.repos[1] + sample.trans[1]:view(1,3):expand(sample.repos[1]:size()))
      repos[i]:copy(output[1]:float()[1])
      trans[i]:copy(output[2]:float()[1])
      focal[i]:copy(output[3]:float()[1])
    end

    xlua.progress(i, size)
  end
  self.model:training()

  if self.nOutput ~= 1 then
    -- Sort preds by inds
    local inds, i = torch.sort(inds)
    poses = poses:index(1, i)
    repos = repos:index(1, i)
    if trans then trans = trans:index(1, i) end
    if focal then focal = focal:index(1, i) end
    if proj then proj = proj:index(1, i) end

    -- Save final predictions
    matio.save(self.opt.save .. '/preds_' .. split .. '.mat',
        {poses = poses, repos = repos, trans = trans, focal = focal, proj = proj})
  end
end

function Trainer:getOrigCoord(pred, center, scale)
  for i = 1, pred:size(1) do
    for j = 1, pred:size(2) do
      pred[i][j] = img.transform(pred[i][j], center[i], scale[i][1], 0,
          self.opt.inputRes, true, false)
    end
  end
  return pred
end

function Trainer:getRef(scale)
  if self.opt.dataset == 'h36m' then
    return 200 * scale:view(-1)
  end
  if self.opt.dataset == 'penn-crop' then
    return 200 * scale:view(-1) / 1.25
  end
end

function Trainer:_computeError(output, target, ref)
-- target: N x d x 2
-- output: N x d x 2
-- ref:    N x 1
  local e, n = {}, {}
  for i = 1, target:size(1) do
    e[i], n[i] = 0.0, 0.0
    for j = 1, target:size(2) do
      if target[i][j][1] ~= 0 and target[i][j][2] ~= 0 then
        local p1 = target[i][j]
        local p2 = output[i][j]
        n[i] = n[i] + 1
        e[i] = e[i] + torch.dist(p1,p2) / ref[i]
      end
    end
  end
  -- TODO: the code above can be made even simpler
  return torch.Tensor(e):sum(), torch.Tensor(n):sum()
end

function Trainer:_computeAccuracy(output, target, ref)
-- target: N x d x 2
-- output: N x d x 2
-- ref:    N x 1
  return eval.coordAccuracy(output, target, 0.05, nil, self.opt.inputRes, ref)
end

return M.Trainer