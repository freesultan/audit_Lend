    attacker in chain 100 > crosschainBorrow(1000e18,usdc,101)

    _ltoken = lusdc
    destLToken = lusdc

    userSuppliedAssets[attacker]= [lusdc]

    entermarket(lusdc)
```c
   (collateral) =  getHypotheticalAccountLiquidityCollateral(attacker, usdc, 0, 0)
    {
        suppliedAssets = [lusdc]
        borrowedAssets= []

        lTokenBalanceInternal = totalInvestment[attacker][lusdc]

        vars.collateralFactor =  0.7//colateral factor for lusdc
        vars.oraclePrice = 10 //lusdc price 


        vars.tokensToDenom = 0.7 x 1.2 x 10


        vars.sumCollateral =
                vars.tokensToDenom  x lTokenBalanceInternal 

        return (vars.sumBorrowPlusEffects, vars.sumCollateral);
    }


        _send(
            101,
            1000,
            0, // Initial borrowIndex, will be set on dest chain
            collateral,
            attacker,
            lusdc,
            address(0), // liquidator
            usdc,
            ContractType.BorrowCrossChain
        );
    

    _lzreceive 

       (
            payload.amount, // 1000
            payload.borrowIndex,// 0 
            payload.collateral, //1.1e18 from attack
            payload.sender, //attacker 
            payload.destlToken, //lusdc
            payload.liquidator,// 0x00
            payload.srcToken,  //usdc
            payload.contractType   //BorrowCrossChain
        )

        _handleBorrowCrossChainRequest(payload, 100);



        

