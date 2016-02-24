function [  ] = plotSolution( x,u,v,d, lbv, ubv, lbu, ubu, ss,obj,times,xScale,uScale,vScale, nScale, uScalePlot,schedules,wellSol,lbuPot,ubuPlot,ulim,minState,maxState,varargin)
%UNTITLED Summary of this function goes here
%   Detailed explanation goes here

% varargin = {'simulate',[],'xScale',xScale,'uScale',cellControlScales,'uScalePlot',cellControlScalesPlot,'schedules',mShootingP.schedules}
% opt = struct('simulate',[],'simFlag',false,'plotWellSols',true,'plotSchedules',true,'plotObjective',true,'pF',@(x)x,'sF',@(x)x,'figN',1000,'wc',false,'reservoirP',[],'plotSweep',false,...
%     'activeComponents',struct('oil',1,'water',1,'gas',0,'polymer',0,'disgas',0,'vapoil',0,'T',0,'MI',0),...% default OW
%     'fluid',[]);

opt = struct('simulate',[],'simFlag',false,'plotWellSols',true, 'plotNetsol', true, 'numNetConstraints', 0, 'plotNetControls', true, 'numNetControls', 0, 'plotCumulativeObjective', false, ...
            'plotSchedules',true,'plotObjective',true,'pF',@(x)x,'sF',@(x)x,'figN',1000,'wc',false,'reservoirP',[],'plotSweep',false,...
            'activeComponents',struct('oil',1,'water',1,'gas',0,'polymer',0,'disgas',0,'vapoil',0,'T',0,'MI',0),...% default OW
            'fluid',[], 'freqCst', 0, 'pressureCst', 0, 'flowCst', 0, 'fixedWells', [], 'stepBreak', numel(v), 'extremePoints', [], ...
            'qlMin', [], 'qlMax', [], 'nStages', [],  'freqMin', [], 'freqMax', [], 'baseFreq', []);
opt = merge_options(opt, varargin{:});

comp = opt.activeComponents;

if ~comp.gas && ~comp.polymer && ~(comp.T || comp.MI)
    plotSolutionOW( x,u,v,d, lbv, ubv, lbu, ubu, ss,obj,times,xScale,uScale,vScale, nScale, uScalePlot,schedules,wellSol,lbuPot,ubuPlot,ulim,minState,maxState,...
        'simulate',opt.simulate,...
        'simFlag',opt.simFlag,...
        'plotWellSols',opt.plotWellSols,...
        'plotNetsol', opt.plotNetsol, ...
        'numNetConstraints', opt.numNetConstraints, ...
        'plotNetControls', opt.plotNetControls, ...
        'numNetControls', opt.numNetControls, ...
        'plotSchedules',opt.plotSchedules,...
        'plotObjective',opt.plotObjective,...
        'pF',opt.pF,...
        'sF',opt.sF,...
        'figN',opt.figN,...
        'wc',opt.wc,...
		'reservoirP',opt.reservoirP,...
		'plotSweep',opt.plotSweep, ...
        'freqCst', opt.freqCst, ...
        'pressureCst', opt.pressureCst, ...
        'flowCst', opt.flowCst, ...
        'fixedWells', opt.fixedWells, ...
        'stepBreak', opt.stepBreak, ...
        'extremePoints', opt.extremePoints,  ...
        'plotCumulativeObjective', opt.plotCumulativeObjective, ...
        'qlMin', opt.qlMin, ...
        'qlMax', opt.qlMax, ...
        'nStages', opt.nStages, ...
        'freqMin', opt.freqMin, ...
        'freqMax', opt.freqMax, ...
        'baseFreq', opt.baseFreq);
    
elseif comp.gas && comp.oil && comp.water
    plotSolutionOWG( x,u,v,d,ss,obj,times,xScale,uScale,vScale,uScalePlot,schedules,wellSol,lbuPot,ubuPlot,ulim,minState,maxState,varargin{:});
else
    error('Not implemented for current activeComponents');
end


end
