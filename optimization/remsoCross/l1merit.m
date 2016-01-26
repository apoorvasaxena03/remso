function [ m,Jac,debugInfo ] = l1merit(f,dE,rho,varargin)
%  l1 merit function definition
%
%  m = f + rho * norm(dE,1)
%
%  optional parameters:
%
%  gradients - true if the partial derivatives must be computed
%
%  fRightSeeds - For jacobain-vector product, f Right-hand-side
%
%  dERightSeeds - For jacobain-vector product, dE Right-hand-side
%
%  leftSeed = Left-hand-side for the vector-jacobian product.
%
%  Returns
%
%  m - merit value
%
%  Jac - Jacobian
%
%  debugInfo - contain the value of the violations

opt = struct('gradients',false,'fRightSeeds',[],'dERightSeeds',[],'leftSeed',1,'debug',false);
opt = merge_options(opt, varargin{:});


debugInfo = struct('f',0,'eq',0,'ineq',0,'eqNorm1',0,'rho',0);
debug = opt.debug;
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%5


penalty = 0;
varN = numel(dE);


for i = 1:varN
    
    dEi = dE{i};
    spmd
        
        
        meqi  =  sum(cellfun(@sumAbs,dEi));
        
        p = gplus(meqi);
        
        
        if debug
            
            deqi =   max(cellfun(@maxAbs,dEi));
            
            deqi = gop(@max,deqi);
            
        end
        
        
    end
    
    penalty = penalty + p{1};
    
    if debug
        debugInfo.eq = max(debugInfo.eq,deqi{1});
    end
    
end

m = f + rho * penalty;

if debug
    debugInfo.f = f;
    debugInfo.eqNorm1 = penalty;
    debugInfo.rho = rho;
end


if opt.gradients
    if ~(size(opt.fRightSeeds,1)==0)
        
        jp = 0;
        for i = 1:numel(dE)
            
            
            dEi = dE{i};
            dERightSeedsi = opt.dERightSeeds{i};
            
            spmd
                jpC = rho * sum(cellfun(@eqLinePenaltyJac,dEi,dERightSeedsi));
                
                jpC = gplus(jpC);
            end
            jp = jp + jpC{1};
        end
        Jac.J = opt.leftSeed*(opt.fRightSeeds + jp);
    else
        error('not implemented')
    end
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



end



function pg = eqLinePenaltyJac(di,rs)
pg = sign(di)'*rs;
end

function ds = sumAbs(x)
ds = sum(abs(x));
end

function m = maxAbs(di)
m = max(abs(di));
end

