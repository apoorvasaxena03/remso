% REservoir Multiple Shooting Optimization.
% REduced Multiple Shooting Optimization.

% Make sure the workspace is clean before we start
clc
clear
clear global

% Required MRST modules
mrstModule add deckformat
mrstModule add ad-fi ad-core ad-props

% Include REMSO functionalities
addpath(genpath('../../mrstDerivated'));
addpath(genpath('../../mrstLink'));
addpath(genpath('../../mrstLink/wrappers/procedural'));
addpath(genpath('../../optimization/multipleShooting'));
addpath(genpath('../../optimization/parallel'));
addpath(genpath('../../optimization/plotUtils'));
addpath(genpath('../../optimization/remso'));
addpath(genpath('../../optimization/remsoCrossSequential'));
addpath(genpath('../../optimization/remsoCross'));
addpath(genpath('../../optimization/singleShooting'));
addpath(genpath('../../optimization/utils'));
addpath(genpath('reservoirData'));

% Open a matlab pool depending on the machine availability
initPool('restart',true);

%% Initialize reservoir -  the Simple reservoir
[reservoirP] = initReservoir( 'simple10x1x10.data','Verbose',true);
%[reservoirP] = initReservoir( 'reallySimpleRes.data','Verbose',true);

% do not display reservoir simulation information!
mrstVerbose off;

% Number of reservoir grid-blocks
nCells = reservoirP.G.cells.num;

%% Multiple shooting problem set up
totalPredictionSteps = numel(reservoirP.schedule.step.val);  % MS intervals

% Schedule partition for each control period and for each simulated step
lastControlSteps = findControlFinalSteps( reservoirP.schedule.step.control );
controlSchedules = multipleSchedules(reservoirP.schedule,lastControlSteps);

uUnscaled  = schedules2CellControls( controlSchedules);
uDims = cellfun(@(uu)size(uu,1),uUnscaled);
totalControlSteps = length(uUnscaled);

stepSchedules = multipleSchedules(reservoirP.schedule,1:totalPredictionSteps);


% Piecewise linear control -- mapping the step index to the corresponding
% control
ci  = arroba(@controlIncidence,2,{reservoirP.schedule.step.control});


%%  Who will do what - Distribute the computational effort!
nWorkers = getNumWorkers();
if nWorkers == 0
    nWorkers = 1;
end
[ jobSchedule ] = divideJobsSequentially(totalPredictionSteps ,nWorkers);
jobSchedule.nW = nWorkers;

work2Job = Composite();
for w = 1:nWorkers
    work2Job{w} = jobSchedule.work2Job{w};
end


[workerCondensingSchedule,clientCondensingSchedule,uStart,workerLoad,avgW] = divideCondensingLoad(totalPredictionSteps,ci,uDims,nWorkers);


jobSchedule.clientCondensingSchedule = clientCondensingSchedule;
jobSchedule.workerCondensingSchedule = workerCondensingSchedule;
jobSchedule.uStart = uStart;


%% Variables Scaling
xScale = setStateValues(struct('pressure',5*barsa,'sW',0.01),'nCells',nCells);


if (isfield(reservoirP.schedule.control,'W'))
    W =  reservoirP.schedule.control.W;
else
    W = processWells(reservoirP.G, reservoirP.rock,reservoirP.schedule.control(1),'DepthReorder', true);
end
wellSol = initWellSolLocal(W, reservoirP.state);
vScale = wellSol2algVar( wellSolScaling(wellSol,'bhp',5*barsa,'qWs',10*meter^3/day,'qOs',10*meter^3/day) );

cellControlScales = schedules2CellControls(schedulesScaling(controlSchedules,...
    'RATE',10*meter^3/day,...
    'ORAT',10*meter^3/day,...
    'WRAT',10*meter^3/day,...
    'LRAT',10*meter^3/day,...
    'RESV',0,...
    'BHP',5*barsa));

%% instantiate the objective function as an aditional Algebraic variable


%%% The sum of the last elements in the algebraic variables is the objective
nCells = reservoirP.G.cells.num;
stepNPV = arroba(@NPVStepM,[1,2],{nCells,'scale',1/10000,'sign',-1},true);

vScale = [vScale;1];

%% Instantiate the simulators for each interval, locally and for each worker.

% ss.stepClient = local (client) simulator instances
% ss.state = scaled initial state
% ss.nv = number of algebraic variables
% ss.ci = piecewice control mapping on the client side
% ss.jobSchedule = Step distribution among workers client side
% ss.work2Job = Step distribution among workers worker side
% ss.step =  worker simulator instances

stepClient = cell(totalPredictionSteps,1);
for k=1:totalPredictionSteps
    cik = callArroba(ci,{k});
    ss.stepClient{k} = @(x0,u,varargin) mrstStep(x0,u,@mrstSimulationStep,wellSol,stepSchedules(k),reservoirP,...
                                        'xScale',xScale,...
                                        'vScale',vScale,...
                                        'uScale',cellControlScales{cik},...
                                        'algFun',stepNPV,...
                                        varargin{:});
end


spmd
    
    stepW = cell(totalPredictionSteps,1);
    for k=1:totalPredictionSteps
        cik = callArroba(ci,{k});
        stepW{k} = arroba(@mrstStep,...
            [1,2],...
            {...
            @mrstSimulationStep,...
            wellSol,...
            stepSchedules(k),...
            reservoirP,...
            'xScale',...
            xScale,...
            'vScale',...
            vScale,...
            'uScale',...
            cellControlScales{cik},...
		    'algFun',stepNPV...
            },...
            true);
    end
    stepC = stepW;
end

ss.state = stateMrst2stateVector( reservoirP.state,'xScale',xScale );

ss.jobSchedule = jobSchedule;
ss.work2Job = work2Job;
ss.step = stepC;
ss.ci = ci;



%% instantiate the objective function


%%% objective function on the client side (for plotting!)
objClient = cell(totalPredictionSteps,1);
for k = 1:totalPredictionSteps
    objClient{k} = arroba(@lastAlg,[1,2,3],{},true);
end
%%% Investigate if it is efficient to evaluate the objective in the workers
spmd
    nJobsW = numel(work2Job);
    objW = cell(nJobsW,1);
    for i = 1:nJobsW
        objW{i} = arroba(@lastAlg,[1,2,3],{},true);
    end
    obj = objW;
end
targetObj = @(xs,u,vs,varargin) sepTarget(xs,u,vs,obj,ss,jobSchedule,work2Job,varargin{:});



%%  Bounds for all variables!

% Bounds for all wells!
maxProd = struct('BHP',200*barsa);
minProd = struct('BHP',(50)*barsa);
maxInj = struct('RATE',250*meter^3/day);
minInj = struct('RATE',0);


% Control input bounds for all wells!
[ lbSchedules,ubSchedules ] = scheduleBounds( controlSchedules,...
    'maxProd',maxProd,'minProd',minProd,...
    'maxInj',maxInj,'minInj',minInj,'useScheduleLims',false);
lbu = schedules2CellControls(lbSchedules,'cellControlScales',cellControlScales);
ubu = schedules2CellControls(ubSchedules,'cellControlScales',cellControlScales);

% Bounds for all wells!
maxProd = struct('ORAT',200*meter^3/day,'WRAT',200*meter^3/day,'GRAT',200*meter^3/day,'BHP',200*barsa);
minProd = struct('ORAT',0,  'WRAT',0,  'GRAT',0,'BHP',(50)*barsa);
maxInj = struct('ORAT',250*meter^3/day,'WRAT',250*meter^3/day,'GRAT',250*meter^3/day,'BHP',(400)*barsa);
minInj = struct('ORAT',0,  'WRAT',0,  'GRAT',0,'BHP',(100)*barsa);

% wellSol bounds  (Algebraic variables bounds)
[ubWellSol,lbWellSol] = wellSolScheduleBounds(wellSol,...
    'maxProd',maxProd,...
    'maxInj',maxInj,...
    'minProd',minProd,...
    'minInj',minInj);
ubvS = wellSol2algVar(ubWellSol,'vScale',vScale);
lbvS = wellSol2algVar(lbWellSol,'vScale',vScale);
lbv = repmat({[lbvS;-inf]},totalPredictionSteps,1);
ubv = repmat({[ubvS;inf]},totalPredictionSteps,1);

% State lower and upper - bounds
maxState = struct('pressure',600*barsa,'sW',1);
minState = struct('pressure',100*barsa,'sW',0.1);
ubxS = setStateValues(maxState,'nCells',nCells,'xScale',xScale);
lbxS = setStateValues(minState,'nCells',nCells,'xScale',xScale);
lbx = repmat({lbxS},totalPredictionSteps,1);
ubx = repmat({ubxS},totalPredictionSteps,1);


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Max saturation for well producer cells

% get well perforation grid block set
prodInx  = (vertcat(wellSol.sign) < 0);
wc    = vertcat(W(prodInx).cells);

maxSat = struct('pressure',inf,'sW',1);
ubxS = setStateValues(maxSat,'x',ubxS,'xScale',xScale,'cells',wc);
ubxsatWMax = repmat({ubxS},totalPredictionSteps,1);
ubx = cellfun(@(x1,x2)min(x1,x2),ubxsatWMax,ubx,'UniformOutput',false);



%% Initial Active set!
initializeActiveSet = true;
if initializeActiveSet
    vDims = cellfun(@numel,lbv);
    [ lowActive,upActive ] = activeSetFromWells(vDims,reservoirP,totalPredictionSteps);
else
    lowActive = [];
    upActive = [];
end





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

[uMlb] = scaleSchedulePlot(lbu,controlSchedules,cellControlScales,cellControlScalesPlot);
[uLimLb] = min(uMlb,[],2);
ulbPlob = cell2mat(arrayfun(@(x)[x,x],uMlb,'UniformOutput',false));


[uMub] = scaleSchedulePlot(ubu,controlSchedules,cellControlScales,cellControlScalesPlot);
[uLimUb] = max(uMub,[],2);
uubPlot = cell2mat(arrayfun(@(x)[x,x],uMub,'UniformOutput',false));


% be carefull, plotting the result of a forward simulation at each
% iteration may be very expensive!
% use simFlag to do it when you need it!
simFunc =@(sch,varargin) runScheduleADI(reservoirP.state, reservoirP.G, reservoirP.rock, reservoirP.system, sch,'force_step',false,varargin{:});


wc    = vertcat(W.cells);
fPlot = @(x)[max(x);min(x);x(wc)];

%prodInx  = (vertcat(wellSol.sign) < 0);
%wc    = vertcat(W(prodInx).cells);
%fPlot = @(x)x(wc);

plotSol = @(x,u,v,xd,varargin) plotSolution( x,u,v,xd,ss,objClient,times,xScale,cellControlScales,vScale,cellControlScalesPlot,controlSchedules,wellSol,ulbPlob,uubPlot,[uLimLb,uLimUb],minState,maxState,'simulate',simFunc,'plotWellSols',true,'plotSchedules',false,'pF',fPlot,'sF',fPlot,varargin{:});

%%  Initialize from previous solution?

if exist('optimalVars.mat','file') == 2
    load('optimalVars.mat','x','u','v');
elseif exist('itVars.mat','file') == 2
    load('itVars.mat','x','u','v');
else
    x = [];
    v = [];
    u  = schedules2CellControls( controlSchedules,'cellControlScales',cellControlScales);
    %[x] = repmat({ss.state},totalPredictionSteps,1);
end

algorithm = 'remso';
switch algorithm
    
    case 'remso'
        %% call REMSO
        
        [u,x,v,f,xd,M,simVars] = remso(u,ss,targetObj,'lbx',lbx,'ubx',ubx,'lbv',lbv,'ubv',ubv,'lbu',lbu,'ubu',ubu,...
            'tol',1e-6,'lkMax',4,'debugLS',true,...
            'lowActive',lowActive,'upActive',upActive,...
            'plotFunc',plotSol,'max_iter',500,'x',x,'v',v,'debugLS',false,'saveIt',false);
        
        %% plotSolution
        plotSol(x,u,v,xd,'simFlag',true);
        
        
        
    case 'snopt'
        
        
        
        objSparsity = ones(1,size(cell2mat(u),1));
        
        uDim = cellfun(@(x)size(x,1),u);
        [outputCons,lbC,ubC,consSparsity] = outputVarsBoundSelector(lbx,ubx,lbv,ubv,uDim,ci);
        
        consSizes = cellfun(@(x)size(x,1),lbC);
        cons = cell(numel(consSizes),1);
        for k=1:size(cons)
            cons{k} = arroba(@concatenateTargetK,[2,3,4],{k,outputCons{k},consSizes},true);
        end
        
        outDims = [1,sum(cellfun(@(x)size(x,1),consSparsity))];
        [ target ] = concatenateTargets(objClient,cons,outDims);
        
        
        
        objCons = @(u,varargin) simulateSystemSS(u,ss,target,'abortNotConvergent',true,varargin{:});
        
        
        
        
        objGradFG = @(uu) dealSnoptSimulateSS( uu,objCons,cellfun(@(x)numel(x),u),true);
        
        optionsSNOPT = which('options.spc');
        if ~strcmp(optionsSNOPT,'')
            snspec(optionsSNOPT);
        end
        
        sparsity = [objSparsity;cell2mat(consSparsity)];
        
        
        snset  ('Minimize');
        snseti('Derivative Option',1);
        snscreen on
        
        ObjAdd = 0;
        ObjRow = 1;
        
        A= [];
        iAfun = [];
        jAvar = [];
        
        [iGfun,jGvar] = find(sparsity);
        
        if size(iGfun,1) < size(iGfun,2)
            iGfun = iGfun';
            jGvar = jGvar';
        end
        
        if exist('snoptLog.txt','file')==2
            delete('snoptLog.txt');
        end
        if exist('snoptSummary.txt','file')==2
            delete('snoptSummary.txt');
        end
        if exist('snoptDetail.txt','file')==2
            delete('snoptDetail.txt');
        end
        snsummary( 'snoptSummary.txt');
        snprintfile( 'snoptDetail.txt');
        
        [u,F,inform,xmul,Fmul] = snopt(cell2mat(u),...
            cell2mat(lbu),...
            cell2mat(ubu),...
            [-inf;cell2mat(lbC)],...
            [ inf;cell2mat(ubC)],...
            objGradFG,...
            ObjAdd,ObjRow,...
            A, iAfun, jAvar, iGfun, jGvar);
        
        snsummary( 'off');
        snprintfile( 'off');
        
        %{
        u = u.*cell2mat(cellControlScales);
        uC = mat2cell(u,uDims,1);
        schedule = cellControls2Schedule( uC,reservoirP.schedule );
        [wellSols,States] = simFunc(schedule);
        [qWs, qOs, qGs, bhp] = wellSolToVector(wellSols);
        
        figure(1)
        plot(cumsum(reservoirP.schedule.step.val),qWs*day)
        title('water (meter^3/day)')
        
        figure(2)
        plot(cumsum(reservoirP.schedule.step.val),qOs*day)
        title('oil (meter^3/day)')
        
        figure(3)
        plot(cumsum(reservoirP.schedule.step.val),bhp/barsa)
        title('bhp (barsa)')
        %}
    case 'ipopt'
        objectiveSS = @(u,varargin) simulateSystemSS(u,ss,objClient,varargin{:});
        
        objSparsity = ones(1,size(cell2mat(u),1));
        
        uDim = cellfun(@(x)size(x,1),u);
        [outputCons,lbC,ubC,consSparsity] = outputVarsBoundSelector(lbx,ubx,lbv,ubv,uDim,ci);
        
        consSizes = cellfun(@(x)size(x,1),lbC);
        cons = cell(numel(consSizes),1);
        for k=1:size(cons)
            cons{k} = @(xsk,vsk,uk,varargin) concatenateTargetK(k,xsk,vsk,uk,outputCons{k},consSizes,varargin{:});
        end
        
        constraintSS = @(u,varargin) simulateSystemSS(u,ss,cons,varargin{:});
        
        
        x0         = cell2mat(u);   % The starting point.
        options.lb = cell2mat(lbu);  % Lower bound on the variables.
        options.ub = cell2mat(ubu);  % Upper bound on the variables.
        options.cl = cell2mat(lbC);   % Lower bounds on the constraint functions.
        options.cu = cell2mat(ubC);   % Upper bounds on the constraint functions.
        
        [ fM ] = memorizeLastSimulation(u,[],true);
        
        
        fwdObj = @(x) ssFwdMemory(mat2cell(x,uDim,1),...
            @(xx,varargin)objectiveSS(xx,'gradients',false,varargin{:}),...
            fM,...
            'replace',false);
        gradObj = @(x) cell2mat(ssFwdMemory(mat2cell(x,uDim,1),...
            @(xx,varargin)objectiveSS(xx,'gradients',true,varargin{:}),...
            fM,...
            'replace',true,'gradFirst',true));
        fwdCons = @(x) ssFwdMemory(mat2cell(x,uDim,1),...
            @(xx,varargin)constraintSS(xx,'gradients',false,varargin{:}),...
            fM,...
            'replace',false);
        gradCons = @(x) sparse(cell2mat(ssFwdMemory(mat2cell(x,uDim,1),...
            @(xx,varargin)constraintSS(xx,'gradients',true,varargin{:}),...
            fM,...
            'replace',true,'gradFirst',true)));
        
        % The callback functions.
        funcs.objective        = fwdObj;
        funcs.gradient         = gradObj;
        funcs.constraints       = fwdCons;
        funcs.jacobian          = gradCons;
        funcs.jacobianstructure = @(x) sparse(cell2mat(consSparsity));
        %funcs.iterfunc         = @callback;
        
        % Set the IPOPT options.
        options.ipopt.hessian_approximation = 'limited-memory';
        options.ipopt.tol         = 1e-7;
        options.ipopt.max_iter    = 100;
        
        % Run IPOPT.
        [x info] = ipopt(x0,funcs,options);
        
        
    otherwise
        
        error('algorithm must be either remso, ipopt, or snopt')
        
        
end