function [ stateVector,Jac ] = stateMrst2stateVector( stateMrst,varargin )
%
%
%  flatten a mrst state as a state vector
%  TODO: reimplement using finalStepVars!
%
%
opt = struct('xScale',[],'partials',false);
opt = merge_options(opt, varargin{:});

stateVector = stateMrst.s(:,1);

if opt.partials
    Jac = speye(numel(stateVector));
end


if ~isempty(opt.xScale)
    stateVector = stateVector./opt.xScale;
    if opt.partials
        Jac = bsxfun(@ldivide,opt.xScale,Jac);
    end
end


end