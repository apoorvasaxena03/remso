% REservoir Multiple Shooting Optimization.
% REduced Multiple Shooting Optimization.

% Make sure the workspace is clean before we start
clc
clear
clear global

% Required MRST modules
mrstModule add deckformat
mrstModule add ad-fi ad-core ad-props

here = fileparts(mfilename('fullpath'));
if isempty(here)
here = pwd();
end

% Include REMSO functionalities
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'mrstDerivated')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'mrstLink')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'mrstLink',filesep,'wrappers',filesep,'procedural')));

addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'netLink')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'netLink',filesep,'plottings')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'netLink',filesep,'dpFunctions',filesep,'fluidProperties')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'netLink',filesep,'dpFunctions',filesep,'pipeFlow')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'netLink',filesep,'networkFunctions')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'netLink',filesep,'auxiliaryFunctions')));

addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'optimization',filesep,'multipleShooting')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'optimization',filesep,'plotUtils')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'optimization',filesep,'remso')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'optimization',filesep,'remsoSequential')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'optimization',filesep,'remsoCrossSequential')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'optimization',filesep,'singleShooting')));
addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'optimization',filesep,'utils')));
addpath(genpath(fullfile(here,filesep,'reservoirData')));


%% Initialize reservoir -  the Simple reservoir
% [reservoirP] = initReservoir('RATE10x5x10.txt', 'Verbose',true);

[reservoirP] = loadEgg('./reservoirData/Egg_Model_Data_Files_v2/MRST');

mrstVerbose off;

% Number of reservoir grid-blocks
nCells = reservoirP.G.cells.num;

%% Multiple shooting problem set up
totalPredictionSteps = numel(reservoirP.schedule.step.val);  % MS intervals

% Schedule partition for each control period and for each simulated step
lastControlSteps = findControlFinalSteps( reservoirP.schedule.step.control );
controlSchedules = multipleSchedules(reservoirP.schedule,lastControlSteps);

stepSchedules = multipleSchedules(reservoirP.schedule,1:totalPredictionSteps);

% Piecewise linear control -- mapping the step index to the corresponding
% control
ci  = arroba(@controlIncidence, 2 ,{reservoirP.schedule.step.control});

%% Variables Scaling
xScale = setStateValues(struct('pressure',5*barsa,'sW',0.01),'nCells',nCells);

if (isfield(reservoirP.schedule.control,'W'))
    W =  reservoirP.schedule.control.W;
else
    W = processWells(reservoirP.G, reservoirP.rock,reservoirP.schedule.control(1),'DepthReorder', true);
end
wellSol = initWellSolLocal(W, reservoirP.state);
for k = 1:numel(wellSol)
    wellSol(k).qGs = 0;
end
nW = numel(W);

%% Fixing Injectors
fixedWells = find(vertcat(W.sign) == 1); % fixing injectors
controlWells = setdiff(1:nW, fixedWells);

% Instantiate the production network object
netSol = prodNetwork(wellSol, 'espNetwork', true, 'withPumps', true);

%%TODO: separate scalling of vk and nk.
%% Scallings
[vScale] = mrstAlg2algVar( wellSolScaling(wellSol,'bhp',5*barsa,'qWs',10*meter^3/day,'qOs',10*meter^3/day, 'freq', 15), netSolScaling(netSol));

freqScale = [15;15;15;15]; % in Hz
flowScale = [5*(meter^3/day); 5*(meter^3/day);5*(meter^3/day);5*(meter^3/day); ...
    5*(meter^3/day); 5*(meter^3/day);5*(meter^3/day);5*(meter^3/day)];

pressureScale = [5*barsa;5*barsa;5*barsa;5*barsa;];

% number of pump stages
numStages =  [90; 90; 90; 90];

%% Feasible initial guess
qlMin = [85*(meter^3/day); ... % PROD1
         65*(meter^3/day); ...% PROD3
         225*(meter^3/day); ... % PROD2
         75*(meter^3/day)];    % PROD4
     
qlMax = [195*(meter^3/day); ...  % PROD1
         195*(meter^3/day); ...  % PROD3
         405*(meter^3/day); ...  % PROD2
         185*(meter^3/day);];    % PROD4\

% bounds for pump frequencies in Hz
freqMin = [40; ... % PROD1
           40; ... % PROD3
           40; ... % PROD2
           40;];   % PROD4
       
freqMax = [80; ... % PROD1
           80; ... % PROD3
           80; ... % PROD2
           80;];   % PROD4
       
baseFreq = [60; 60; 60; 60;]; % in Hz



% function that performs a network simulation, and calculates the
% pressure drop (dp) in the chokes/pumps

cellControlScales = schedules2CellControls(schedulesScaling(controlSchedules,...
    'RATE',10*meter^3/day,...
    'ORAT',10*meter^3/day,...
    'WRAT',10*meter^3/day,...
    'LRAT',10*meter^3/day,...
    'RESV',0,...
    'BHP',5*barsa),'fixedWells', fixedWells);

%% instantiate the objective function as an aditional Algebraic variable
%%% The sum of the last elements in the algebraic variables is the objective
nCells = reservoirP.G.cells.num;

nScale  = [flowScale; freqScale; pressureScale];
vScale = [vScale; nScale; 1];

networkJointObj = arroba(@networkJointNPVConstraints,[1,2],{nCells, netSol, freqScale, pressureScale, flowScale, numStages, baseFreq, qlMin, qlMax, 'scale',1/100000,'sign',-1, 'dpFunction', @dpBeggsBrillJDJ, 'finiteDiff', true, 'forwardGradient', true},true);

step = cell(totalPredictionSteps,1);
for k=1:totalPredictionSteps
    cik = callArroba(ci,{k});
    step{k} = @(x0,u,varargin) mrstStep(x0,u,@mrstSimulationStep,wellSol,stepSchedules(k),reservoirP,...
        'xScale',xScale,...
        'vScale',vScale,...
        'uScale',cellControlScales{cik},...
        'algFun',networkJointObj,...
        'fixedWells', fixedWells, ...
        'saveTargetJac', true,...
        varargin{:});
end

ss.state = stateMrst2stateVector( reservoirP.state,'xScale',xScale );
ss.step = step;
ss.ci = ci;

%% instantiate the objective function
obj = cell(totalPredictionSteps,1);
for k = 1:totalPredictionSteps
    obj{k} = arroba(@lastAlg,[1,2,3],{},true);
end
targetObj = @(xs,u,vs,varargin) sepTarget(xs,u,vs,obj,ss,varargin{:});

%%  Bounds for all variables!

%%  Bounds for all variables!

% Bounds for all wells!
% minProd = struct('BHP',130*barsa, 'ORAT', 1*meter^3/day); original val
minProd = struct('BHP',100*barsa, 'ORAT',  1*meter^3/day);

% maxProd = struct('BHP',200*barsa, 'ORAT', 220*meter^3/day); original val
maxProd = struct('BHP',450*barsa, 'ORAT', inf*meter^3/day);

% minInj = struct('RATE',100*meter^3/day); % original val
minInj = struct('RATE',1*meter^3/day);
% maxInj = struct('RATE',300*meter^3/day); original val

% maxInj = struct('RATE',300*meter^3/day);
maxInj = struct('RATE',500*meter^3/day);

% Control input bounds for all wells!

[ lbSchedules,ubSchedules ] = scheduleBounds( controlSchedules,...
    'maxProd',maxProd,'minProd',minProd,...
    'maxInj',maxInj,'minInj',minInj,'useScheduleLims',false);
lbw = schedules2CellControls(lbSchedules,'cellControlScales',cellControlScales, 'fixedWells', fixedWells);
ubw = schedules2CellControls(ubSchedules,'cellControlScales',cellControlScales, 'fixedWells', fixedWells);


cellControlScale = cellfun(@(wi) wi,cellControlScales,'uniformOutput', false);

lbu = cellfun(@(wi) wi,lbw, 'UniformOutput',false);
ubu = cellfun(@(wi) wi,ubw, 'UniformOutput',false);


% Bounds for all wells!
% minProd = struct('ORAT',1*meter^3/day,  'WRAT',1*meter^3/day,  'GRAT',
% -inf,'BHP',130*barsa); original val
minProd = struct('ORAT', -inf,  'WRAT', -inf,  'GRAT', -inf,'BHP',-inf);
% maxProd = struct('ORAT',220*meter^3/day,'WRAT',150*meter^3/day,'GRAT',
% inf,'BHP',350*barsa); original val
maxProd = struct('ORAT', inf,'WRAT', inf,'GRAT', inf,'BHP',inf);

% minInj = struct('ORAT',-inf,  'WRAT',100*meter^3/day,  'GRAT',
% -inf,'BHP', 5*barsa); original val
minInj = struct('ORAT',-inf,  'WRAT', -inf,  'GRAT', -inf,'BHP', -inf);
% maxInj = struct('ORAT',inf,'WRAT',300*meter^3/day,'GRAT',
% inf,'BHP',500*barsa); original val
maxInj = struct('ORAT',inf,'WRAT', inf ,'GRAT', inf,'BHP', inf);

% wellSol bounds  (Algebraic variables bounds)
[ubWellSol,lbWellSol] = wellSolScheduleBounds(wellSol,...
    'maxProd',maxProd,...
    'maxInj',maxInj,...
    'minProd',minProd,...
    'minInj',minInj);

ubvS = wellSol2algVar(ubWellSol,'vScale',vScale);
lbvS = wellSol2algVar(lbWellSol,'vScale',vScale);

%% Linear Approx. of Pump Map
% lbv = repmat({[lbvS; 0./flowScale;   0*barsa./pressureScale; 0*barsa./pressureScale;  -inf*barsa./pressureScale; -inf]},totalPredictionSteps,1);
% ubv = repmat({[ubvS; inf./flowScale; inf*barsa./pressureScale; inf*barsa./pressureScale;  0*barsa./pressureScale; inf]},totalPredictionSteps,1);

% Non-Linear Pump Map Constraints
lbv = repmat({[lbvS; 0./flowScale;   freqMin./freqScale;   -inf]},totalPredictionSteps,1);
ubv = repmat({[ubvS; inf./flowScale; freqMax./freqScale;    inf]},totalPredictionSteps,1);

% lbv = repmat({[lbvS; -inf./flowScale;   -inf./freqScale;   -inf]},totalPredictionSteps,1);
% ubv = repmat({[ubvS; inf./flowScale;    inf./freqScale;    inf]},totalPredictionSteps,1);

% State lower and upper - bounds
maxState = struct('pressure',1000*barsa,'sW',1);
minState = struct('pressure',50*barsa,'sW',0.1);
ubxS = setStateValues(maxState,'nCells',nCells,'xScale',xScale);
lbxS = setStateValues(minState,'nCells',nCells,'xScale',xScale);
lbx = repmat({lbxS},totalPredictionSteps,1);
ubx = repmat({ubxS},totalPredictionSteps,1);


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
lowActive = [];
upActive = [];

%% A plot function to display information at each iteration

times.steps = [stepSchedules(1).time;arrayfun(@(x)(x.time+sum(x.step.val))/day,stepSchedules)];
times.tPieceSteps = cell2mat(arrayfun(@(x)[x;x],times.steps,'UniformOutput',false));
times.tPieceSteps = times.tPieceSteps(2:end-1);

times.controls = [controlSchedules(1).time;arrayfun(@(x)(x.time+sum(x.step.val))/day,controlSchedules)];
times.tPieceControls = cell2mat(arrayfun(@(x)[x;x],times.controls,'UniformOutput',false));
times.tPieceControls = times.tPieceControls(2:end-1);

cellControlScalesPlot = schedules2CellControls(schedulesScaling( controlSchedules,'RATE',1/(meter^3/day),...
    'ORAT',1/(meter^3/day),...
    'WRAT',1/(meter^3/day),...
    'LRAT',1/(meter^3/day),...
    'RESV',0,...
    'BHP',1/barsa));

cellControlScalesPlot = cellfun(@(w) [w], cellControlScalesPlot, 'UniformOutput',false);

cellControlScales  = cellfun(@(w) [w] , cellControlScales ,'uniformOutput', false);

[uMlb] = scaleSchedulePlot(lbu,controlSchedules,cellControlScales,cellControlScalesPlot, 'fixedWells', fixedWells);
[uLimLb] = min(uMlb,[],2);
ulbPlob = cell2mat(arrayfun(@(x)[x,x],uMlb,'UniformOutput',false));


[uMub] = scaleSchedulePlot(ubu,controlSchedules,cellControlScales,cellControlScalesPlot, 'fixedWells', fixedWells);
[uLimUb] = max(uMub,[],2);
uubPlot = cell2mat(arrayfun(@(x)[x,x],uMub,'UniformOutput',false));

% be carefull, plotting the result of a forward simulation at each
% iteration may be very expensive!
% use simFlag to do it when you need it!
simFunc =@(sch,varargin) runScheduleADI(reservoirP.state, reservoirP.G, reservoirP.rock, reservoirP.system, sch,'force_step',false,varargin{:});

wc    = vertcat(W.cells);
fPlot = @(x)[max(x);min(x);x(wc)];

plotSol = @(x,u,v,d,varargin) plotSolution( x,u,v,d, lbv, ubv, lbu, ubu, ss,obj,times,xScale,cellControlScales,vScale, nScale, ...
    cellControlScalesPlot,controlSchedules,wellSol, netSol, ulbPlob,uubPlot,[uLimLb,uLimUb],minState,maxState,'simulate',simFunc,'plotWellSols',true, 'plotNetsol', false, ...
    'numNetConstraints', numel(nScale), 'plotNetControls', false, 'freqCst', numel(freqScale), 'pressureCst',numel(pressureScale),  'flowCst',numel(flowScale), ...
    'plotSchedules',false,'pF',fPlot,'sF',fPlot, 'fixedWells', fixedWells, 'plotCumulativeObjective', true, 'qlMin', qlMin,  'qlMax', qlMax, 'nStages', numStages, ...
    'freqMin', freqMin, 'freqMax', freqMax, 'baseFreq', baseFreq, 'reservoirP', reservoirP, 'plotNetwork', true, 'dpFunction', @dpBeggsBrillJDJ,  varargin{:});

% remove network control to initialize well controls vector (w)
cellControlScales = cellfun(@(w) w(1:end) ,cellControlScales, 'UniformOutput', false);

%%  Initialize from previous solution?
x = [];
v = [];
w  = schedules2CellControls( controlSchedules,'cellControlScales',cellControlScales, 'fixedWells', fixedWells);

cellControlScales = cellfun(@(w) [w] , cellControlScales ,'uniformOutput', false);
u = cellfun(@(wi)[wi],w,'UniformOutput',false);

cellControlScalesPlot = cellfun(@(w) [w], cellControlScalesPlot,'uniformOutput', false);

testFlag = false;
if testFlag
    addpath(genpath(fullfile(here,filesep,'..',filesep,'..',filesep,'optimization',filesep,'testFunctions')));
    [~, ~, ~, simVars, xs, vs] = simulateSystemSS(u, ss, []);
    [ei, fi, vi] = testProfileGradients(xs,u,vs,ss.step,ss.ci,ss.state, 'd', 1, 'pert', 1e-5, 'all', false);
end

optmize = false;
loadPrevSolution = true;
plotSolution = true;


if isempty(x)
    x = cell(totalPredictionSteps,1);
end
if isempty(v)
    v = cell(totalPredictionSteps,1);
end
xd = cell(totalPredictionSteps,1);
ssK = ss;

uK = u(1);
kFirst = 1;
iC = 1;
if loadPrevSolution
    load greedyStrategy;
end

recoverPreviousSolution = false;
if recoverPreviousSolution
    load greedyStrategy.mat;
    iC = kLast;
    lastControlSteps = lastControlSteps(kLast:end);
    kFirst = kLast;
    ssK.state = lastState;
end

if optmize
    for kLast = lastControlSteps'
        kLast
        if loadPrevSolution
            uK = u(iC);
            xK = x(kFirst:kLast);
            vK = v(kFirst:kLast);
        else
            xK = [];
            vK = [];
            if iC > 1
                uK = u(iC-1);
            end
        end
        
        totalPredictionStepsK = kLast-kFirst+1;
        
        ssK.step = ss.step(kFirst:kLast);
        ssK.ci  = arroba(@controlIncidence,2,{ones(totalPredictionStepsK,1)});
        
        lbxK = lbx(kFirst:kLast);
        ubxK = ubx(kFirst:kLast);
        lbvK = lbv(kFirst:kLast);
        ubvK = ubv(kFirst:kLast);
        lbuK = lbu(iC);
        ubuK = ubu(iC);
        
        obj = cell(totalPredictionStepsK,1);
        for k = 1:totalPredictionStepsK
            obj{k} = arroba(@lastAlg,[1,2,3],{},true);
        end
        targetObjK = @(xs,u,vs,varargin) sepTarget(xs,u,vs,obj,ssK,varargin{:});
        
        
        [ukS,xkS,vkS,f,xdK,M,simVars,converged] = remso(uK,ssK,targetObjK,'lbx',lbxK,'ubx',ubxK,'lbv',lbvK,'ubv',ubvK,'lbu',lbuK,'ubu',ubuK,...
            'tol',1e-6,'lkMax',4,'debugLS',false,...
            'skipRelaxRatio',inf,...
            'lowActive',[],'upActive',[],...
            'plotFunc',plotSol,'max_iter', 500,'x',xK,'v',vK,'saveIt',false, 'condense', true,'computeCrossTerm',false, 'qpAlgorithm', 1);
        
        x(kFirst:kLast) = xkS;
        v(kFirst:kLast) = vkS;
        xd(kFirst:kLast) = xdK;
        u(iC) = ukS;
        
        kFirst = kLast+1;
        ssK.state = xkS{end};
        lastState = ssK.state;
        iC = iC+1;
        save('greedyStrategy.mat', 'lastState', 'u', 'kLast');
    end
    save('greedyStrategy.mat','x', 'xd', 'v', 'u');
end

if plotSolution
    if ~optmize && ~loadPrevSolution
        [~, ~, ~, simVars, x, v] = simulateSystemSS(u, ss, []);
    end
    xd = cellfun(@(xi)xi*0,x,'UniformOutput',false);
    plotSol(x,u,v,xd, 'simFlag', false);    
    
%     figlist=findobj('type','figure');
%     dirname = 'figs/';
%     if ~(exist(dirname,'dir')==7)
%         mkdir(dirname);
%     end
%     
%     for i=1:numel(figlist)
%         saveas(figlist(i),fullfile(dirname, ['figure' num2str(figlist(i).Number) '.eps']), 'epsc');    
%     end
%     close all;
end